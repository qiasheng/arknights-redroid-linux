# 03 · 网络与 MTU：为什么「能登录，但下载卡住 / 一直断流」

## 1. 现象

- 游戏能过热更校验，能进登录页；
- 下载游戏资源时速度掉到 0，或者进度条长时间不动，过一会儿报「网络异常」；
- 有时能下载几十 MB，然后卡死；
- 容器里 `ping` 通、DNS 能解析、网页小请求正常；
- 宿主机的网络完全正常，同网络下别的设备下载很快。

这不是「网速慢」，是 **MTU 不匹配导致的 PMTUD 黑洞**。

## 2. 根因

这条线路是 PPPoE 拨号，WAN 侧 MTU 是 **1492**（PPPoE 头占 8 字节，1500 - 8 = 1492）。

实际链路：

| 接口 | MTU | 说明 |
|---|---|---|
| `enp7s0`（物理网卡） | 1492 | PPPoE，正确 |
| `podman0`（容器网桥） | 默认 1500 | ❌ 比链路大 |
| 容器 `eth0` | 默认 1500 | ❌ 继承网桥 |

于是：

1. 容器里的 TCP 按 1500 协商 MSS（1460）；
2. 发出的 1500 字节包到了 PPPoE 链路上放不下，被丢弃；
3. 正常情况路由器应该回 ICMP `fragmentation needed`，让发送方降 MSS —— 但 PPPoE / 运营商 / NAT 经常把这类 ICMP 吞掉；
4. 发送方永远等不到「包太大」的反馈，继续重传 1500 字节的包 → 大流量卡死。

小包（DNS、HTTP 头、TLS 握手的前几个包）能过，所以表现为「能登录、能校验，但一下载就卡」。这也是最容易误判成 DNS 或 CDN 问题的地方。

## 3. 验证：找到精确的 MTU 天花板

`ping -s` 指定的是 **ICMP 载荷**，整包 = 载荷 + 28（20 字节 IPv4 头 + 8 字节 ICMP 头）。所以 MTU 1492 对应载荷 **1464**。

在**宿主**上测：

```bash
# 1464 + 28 = 1492，应该通
ping -M do -s 1464 -c 3 8.8.8.8

# 1465 + 28 = 1493，应该 100% 丢包
ping -M do -s 1465 -c 3 8.8.8.8
```

在**容器网络命名空间**里测（用的是宿主的 ping，但走容器的网卡）：

```bash
CPID=$(sudo podman inspect -f '{{.State.Pid}}' redroid-arknights)

sudo nsenter -t "$CPID" -n ping -M do -s 1464 -c 3 8.8.8.8   # 通
sudo nsenter -t "$CPID" -n ping -M do -s 1465 -c 3 8.8.8.8   # 丢
```

如果容器里 1464 也不通，说明容器 eth0 还是 1500，或者上层还有别的问题。

> ⚠️ 判断丢包不要用 `grep "0% packet loss"`：`100% packet loss` 里也包含 `0% packet loss`，会全部误判为通。用 `grep -w "0% packet loss"`，或者直接看 `ping` 的退出码。

## 4. 修复

需要同时改 **网桥** 和 **容器 eth0**。改完立刻生效，不需要重启容器。

```bash
# 1) 网桥
sudo ip link set podman0 mtu 1492

# 2) 容器 eth0（在容器的 netns 里改）
CPID=$(sudo podman inspect -f '{{.State.Pid}}' redroid-arknights)
sudo nsenter -t "$CPID" -n ip link set eth0 mtu 1492
```

### 4.1 封装成脚本（推荐）

仓库里带了 [`scripts/redroid-fix-mtu`](../scripts/redroid-fix-mtu)，装到系统路径：

```bash
sudo install -m 755 scripts/redroid-fix-mtu /usr/local/sbin/redroid-fix-mtu
sudo /usr/local/sbin/redroid-fix-mtu redroid-arknights
```

输出应该类似：

```
redroid-fix-mtu: redroid-arknights eth0=1492 podman0=1492
```

脚本会等容器真的起来（最多 30 秒）再改，适合放在启动流程里。默认容器名是 `redroid-starrail`，所以**一定要传容器名**。

### 4.2 什么时候要重跑

- 每次 `podman restart` 之后：容器 netns 重建，`eth0` 回到 1500。
- 每次宿主机重启之后：`podman0` 重新创建，回到 1500。
- `podman rm` 重建容器之后：同上。

`podman0` 的 MTU 有时在容器重启后能保留，但不要赌，脚本是幂等的，重跑没坏处。

### 4.3 开机自动执行（可选）

如果不想每次手动跑，可以加一个 systemd oneshot：

```ini
# /etc/systemd/system/redroid-fix-mtu.service
[Unit]
Description=Fix MTU for redroid-arknights
After=podman.service
Wants=podman.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/redroid-fix-mtu redroid-arknights

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now redroid-fix-mtu.service
```

> 如果容器是「登录后才启动」或者手动 `podman start` 的，这个 unit 可能跑在容器之前。脚本本身会等 30 秒，但更稳的做法是把它挂到你自己的启动脚本里（`scripts/start-arknights.sh` 已经这么做了）。

### 4.4 另一种思路：MSS clamping

如果不想动 MTU，也可以在网桥上做 TCP MSS 钳制，让容器协商出更小的 MSS：

```bash
# nftables 示例（需要 root，规则不持久）
sudo nft add table inet redroid
sudo nft 'add chain inet redroid post { type filter hook postrouting priority mangle; }'
sudo nft 'add rule inet redroid post oifname "enp7s0" tcp flags syn tcp option maxseg size set rt mtu'
```

`rt mtu` 会按路由 MTU（1492）设置 MSS。这条路对 TCP 有效，对 UDP（游戏语音、部分下载）无效。**优先用改 MTU 的方案**，MSS clamping 只作为兜底。

## 5. 系统设置：私有 DNS 与强制门户

这两条不解决 MTU，但能避免另一类「网络明明通、系统说没网」的问题。

```bash
adb -s 127.0.0.1:5556 shell settings put global private_dns_mode off
adb -s 127.0.0.1:5556 shell settings put global captive_portal_mode 0
```

- `private_dns_mode off`：关掉 DoT。redroid 默认可能尝试走加密 DNS，网络环境不支持时解析会卡住。
- `captive_portal_mode 0`：关掉强制门户检测。容器里没有完整的 Captive Portal 探测链路，系统可能一直认为网络是 `PARTIAL_CONNECTIVITY`，某些应用会因此拒绝下载。

**两条都是 `settings`，存在 `/data` 里，容器重启会保留；但 `podman rm` 重建会丢。** 新容器第一次开机必须补。

验证：

```bash
adb -s 127.0.0.1:5556 shell settings get global private_dns_mode   # off
adb -s 127.0.0.1:5556 shell settings get global captive_portal_mode # 0
```

## 6. DNS 实测：它不是元凶

我们一度怀疑是 DNS 慢 / 被污染，实测反驳了这个方向：

| DNS | 响应时间 |
|---|---|
| 8.8.8.8 | 1.4–1.7 ms |
| 223.5.5.5（阿里） | 1.4–1.7 ms |
| 119.29.29.29（腾讯） | 1.4–1.7 ms |
| 192.168.31.1（路由器） | 1.4–1.7 ms |

容器实际在用 `8.8.8.8`，连续 64 次查询 **0 错误**。延迟低、无丢包、解析正常。

另外试过：

```bash
adb -s 127.0.0.1:5556 shell cmd netd resolver setnetdns 100 "" 223.5.5.5
```

命令返回成功，但 `getprop net.dns1` / 实际解析路径没变，**不生效**。这台机器上也没有必要改：DNS 本来就没问题。

结论：**下载卡住是 MTU，不是 DNS**。不要在 DNS 上继续花时间。

## 7. 修复后的验证清单

```bash
# 1) MTU 三层都对
ip -o link show podman0 | sed 's/.*mtu \([0-9]*\).*/podman0 mtu=\1/'
CPID=$(sudo podman inspect -f '{{.State.Pid}}' redroid-arknights)
sudo nsenter -t "$CPID" -n ip -o link show eth0

# 2) 容器里能解析、能连通
adb -s 127.0.0.1:5556 shell ping -c 3 223.5.5.5
adb -s 127.0.0.1:5556 shell ping -c 3 www.baidu.com

# 3) 大包不丢（在容器 netns 里）
sudo nsenter -t "$CPID" -n ping -M do -s 1464 -c 3 8.8.8.8

# 4) 实际下载：进游戏跑一次资源更新，观察是否还会长时间 0 速度
```

## 7.1 GitHub 能打开，MAA 资源更新却 404

这是另一个很隐蔽的网络坑，和 MTU 无关。

**现象**：浏览器能正常打开 GitHub，但 MAA 检查资源更新时日志里是：

```text
Start to download file from "https://github.com/MaaAssistantArknights/MaaResource/archive/refs/heads/main.zip"
HTTP: NotFound GET https://github.com/MaaAssistantArknights/MaaResource/zip/refs/heads/main
```

**根因**：`/etc/hosts` 里把 `codeload.github.com` 指到了一个错误的 GitHub 节点：

```text
20.205.243.166 codeload.github.com
```

`20.205.243.166` 是 GitHub 的网页节点，不是 codeload。请求 codeload 的 zip 路径时，它会 301 回 `github.com/.../zip/...`，而那个路径本身是 404。

浏览器访问的是 `github.com`，所以看起来“GitHub 完全正常”；MAA 下载资源包走的是 `codeload.github.com`，于是只有它失败。

验证：

```bash
grep codeload /etc/hosts

# 错误 IP：应该看到 301，最后 404
curl -sSI --max-time 10 --resolve codeload.github.com:443:20.205.243.166   https://codeload.github.com/MaaAssistantArknights/MaaResource/zip/refs/heads/main | head

# 正确 IP：应该看到 200 + application/zip
curl -sSI --max-time 10 --resolve codeload.github.com:443:140.82.112.9   https://codeload.github.com/MaaAssistantArknights/MaaResource/zip/refs/heads/main | head
```

**修复宿主**：

```bash
sudo sed -i 's/^20\.205\.243\.166\([[:space:]]\+\)codeload\.github\.com/140.82.112.9\1codeload.github.com/' /etc/hosts
grep codeload /etc/hosts
```

**还要修 Wine 的前缀**：MAA 跑在 Wine 里，Wine 使用的是前缀里的 hosts 文件，不读宿主的 `/etc/hosts`：

```bash
WINEPREFIX=~/Games/maa-prefix
echo '140.82.112.9 codeload.github.com' >> \
  "$WINEPREFIX/drive_c/windows/system32/drivers/etc/hosts"
```

> 这个文件里默认只有 `127.0.0.1 localhost`。加完重启 MAA。

**验证 MAA**：重启后日志应该变成：

```text
HTTP: OK GET https://codeload.github.com/MaaAssistantArknights/MaaResource/zip/refs/heads/main
Remove download temp file X:\Games\MAA\MaaResourceGithub.zip.temp
```

如果 `140.82.112.9` 不通，可以试 `140.82.113.9` / `140.82.114.9`（同一组 codeload 节点）。

> **如果你有 GitHub hosts 自动测速脚本**：不要让脚本用 `github.com` 的最优 IP 去覆盖 `codeload.github.com`。这两个域名不是同一组节点，`20.205.243.166` 这类网页节点会给 codeload 的 zip 请求返回 301 → 404。  
> 本文机器上 `github-release-hosts.sh` 已在开头加了 `ensure_codeload` 保护（每 15 分钟校正一次），`github-hosts-speedtest.sh` 只精确替换 `github.com` 那一行；`start-maa.sh` 在启动前也会把宿主 `/etc/hosts` 里的 codeload IP 同步进 Wine 前缀。三个地方都检查过，定时器不会再把它改坏。

这不是 Lutris 的问题，Lutris 只负责启动 Wine。

## 8. 其他网络坑

- **不要把容器改成 `--network host`**：redroid 的 ADB 端口和宿主网络混在一起，容易和别的服务冲突；而且 MTU 问题依旧存在（只是换了个接口）。
- **端口绑定**：`-p 5556:5555` 会监听 `0.0.0.0`。建议改成 `-p 127.0.0.1:5556:5555`，或者用防火墙挡住。
- **IPv6**：容器里 IPv6 通常是不通的，某些 CDN 会优先解析 AAAA，导致连接超时后回落很慢。如果下载仍然偶发卡顿，可以在容器里关掉 IPv6（需要改容器网络，风险较高，非必要不做）。
- **时间同步**：容器时间漂移会导致 TLS 证书校验失败、签到异常。检查：

  ```bash
  adb -s 127.0.0.1:5556 shell date
  date
  ```

  差得多就 `adb shell su 0 date -s ...`，或者重启容器让它重新同步。

- **代理**：如果宿主机走了代理（TUN / redsocks），容器流量可能不经过代理，或者经过但 MTU 更小。排查时先确认容器是直连还是被代理接管。
