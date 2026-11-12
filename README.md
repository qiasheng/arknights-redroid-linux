# 在 Linux 上用 redroid 跑明日方舟 + MAA 接管

> 一份「踩完所有坑之后」的完整记录。目标是下次重装系统、换机器，或者帮别人搭的时候，直接照着做，不用再花几天排查。

**适用场景**：Linux（没有 Windows、不用官方 PC 客户端）→ redroid 容器跑 Android 版明日方舟 → MAA（Wine / Lutris）通过 ADB 接管。

**一句话结论**：整套方案能稳定跑。卡得最久的「进游戏几十秒后被静默杀掉」，根因不是翻译层、不是 MAA、不是网络，而是 **redroid 镜像派生出的 `ro.build.fingerprint` 有 102 字符，超过 Android 属性可读上限（92 字节含结尾 `\0`，实际最长 91 字符），腾讯 TenProtect 读到空值后判定环境被篡改，主动结束游戏进程**。在 `/system/build.prop` 末尾追加一条 90 字符的合法指纹即可。

---

## 这套东西长什么样

```
┌──────────────────────────────┐
│ 明日方舟 (arm64-v8a, Unity)   │
│   └─ TenProtect 反外挂        │
├──────────────────────────────┤
│ redroid 容器 = Android 11     │
│   x86_64 系统                 │
│   + libndk 翻译层 v0.2.3      │  ← 把 arm64 指令翻译成 x86_64
│   端口 127.0.0.1:5556 → 5555  │
├──────────────────────────────┤
│ Podman（rootful）             │
├──────────────────────────────┤
│ Arch Linux / 内核 7.x         │
└──────────────┬───────────────┘
               │ ADB over TCP
┌──────────────┴───────────────┐
│ MAA v6.x（Windows 版）        │
│   └─ Wine 前缀 + Lutris       │
│   └─ platform-tools\adb.exe   │
└──────────────────────────────┘
```

MAA 只做两件事：通过 ADB 截图、通过 ADB 发送触摸事件。它不关心游戏跑在真机、模拟器还是容器里。

---

## 30 秒速查

```bash
# 1) 容器在跑吗
sudo podman ps --filter name=redroid-arknights

# 2) 每次容器重启后必须补：网络 + 系统设置
sudo /usr/local/sbin/redroid-fix-mtu redroid-arknights
adb -s 127.0.0.1:5556 shell settings put global private_dns_mode off
adb -s 127.0.0.1:5556 shell settings put global captive_portal_mode 0
adb -s 127.0.0.1:5556 shell svc power stayon true

# 3) 指纹是不是坏的（长度 >= 92 必现「进游戏被踢」）
adb -s 127.0.0.1:5556 shell getprop ro.build.fingerprint | awk '{print length($0)}'
# 期望：90

# 4) 翻译层对不对（v0.2.3 的三个 md5）
adb -s 127.0.0.1:5556 shell 'su 0 md5sum /system/lib64/libndk_translation.so'
# 期望：0f8376da34ee3edd10e79105aec478f4

# 5) guest libvulkan 必须处于禁用状态
adb -s 127.0.0.1:5556 shell 'su 0 ls /system/lib64/arm64/libvulkan.so*'
# 只应看到 libvulkan.so.disabled

# 6) 起游戏
adb -s 127.0.0.1:5556 shell am start -n com.hypergryph.arknights/com.u8.sdk.U8UnityContext

# 7) 加载页点底部金色菱形（1920x1080），否则永远停在那里
adb -s 127.0.0.1:5556 shell input tap 960 984

# 8) 登录页点「开始唤醒」
adb -s 127.0.0.1:5556 shell input tap 960 770
```

一键版：`scripts/start-arknights.sh`。

---

## 从零到进游戏：步骤总览

| # | 做什么 | 详细文档 | 必做 |
|---|---|---|---|
| 0 | 检查内核 binder / 装 podman、adb | [01](docs/01-环境与容器.md#0-前置检查) | ✅ |
| 1 | 拉 redroid 镜像 | [01](docs/01-环境与容器.md#1-拉镜像) | ✅ |
| 2 | 创建容器（端口 5556、`use_memfd=1`、GPU host） | [01](docs/01-环境与容器.md#2-创建容器) | ✅ |
| 3 | 首次开机、关私有 DNS / 强制门户检测 | [01](docs/01-环境与容器.md#3-首次开机后必做) | ✅ |
| 4 | 设 1920×1080 / DPI 320 | [01](docs/01-环境与容器.md#5-分辨率) | ✅ |
| 5 | `adb install --abi arm64-v8a` 安装方舟 | [01](docs/01-环境与容器.md#4-安装-apk) | ✅ |
| 6 | 换 libndk v0.2.3 + 禁用 guest `libvulkan.so` | [01](docs/01-环境与容器.md#6-arm-翻译层关键) | ✅ |
| 7 | 修 fingerprint（90 字符） | [02](docs/02-反外挂与指纹.md) | ✅ |
| 8 | 对齐 MTU 1492 | [03](docs/03-网络与MTU.md) | ✅ |
| 9 | 起游戏，点菱形 → 开始唤醒 | [04](docs/04-启动流程与坐标.md) | ✅ |
| 10 | 配 MAA（Wine / Lutris / ADB 5556） | [05](docs/05-MAA接管.md) | ✅ |

排错先看 [06-排错手册](docs/06-排错手册.md)；想知道「为什么试过 XX 但没用」看 [07-踩坑记录](docs/07-踩坑记录.md)。

---

## 我的实际环境

| 项 | 值 |
|---|---|
| 系统 | Arch Linux，16 核 |
| 内核 | 7.2.x-zen（Rust binder，binderfs 挂在 `/dev/binderfs`） |
| 网卡 | RTL8125 2.5G，PPPoE 拨号，**链路 MTU = 1492** |
| 容器运行时 | Podman（rootful，命令前加 `sudo`） |
| 镜像 | `docker.io/redroid/redroid:11.0.0-latest`（Android 11 / SDK 30） |
| 容器名 | `redroid-arknights`，`0.0.0.0:5556 → 5555` |
| 数据目录 | `~/redroid-arknights`（bind 到容器 `/data`） |
| 游戏 | 明日方舟国服 2.7.x，`adb install --abi arm64-v8a` |
| ARM 翻译层 | ChromeOS Android 13 zork libndk v0.2.3 |
| MAA | v6.22.0，Lutris + Wine（dwproton-11.0-14），客户端类型「官服」 |

> 另有一个 `redroid-starrail`（崩铁）跑在 5555。本仓库的所有命令都**只操作 5556 / `redroid-arknights`**，不要顺手 `podman restart` 全部。

---

## 三个核心结论

1. **启动即 `SIGABRT`** → 翻译层 v0.2.3 给 guest `libvulkan.so` 建 proxy 时，要求宿主 `libvulkan.so` 导出 Android 13 才有的 `android_convertGralloc0To1Usage`，Android 11 没有。解法：把 guest 的 `/system/lib64/arm64/libvulkan.so` 改名禁用，Unity 自动回落 GLES。
2. **进游戏被静默杀** → `ro.build.fingerprint` 102 字符 > 91 可读上限，反外挂读到空值。解法：写一条 90 字符的合法指纹进 `/system/build.prop`。
3. **加载页停住不动** → **不是 bug**。这个页面本来就要点底部金色菱形才继续，静置多久都不会自动进。

---

## 常用命令

```bash
# 容器
sudo podman ps -a | grep redroid
sudo podman logs --tail 100 redroid-arknights
sudo podman exec -it redroid-arknights sh
sudo podman restart redroid-arknights

# 投屏看画面（排查坐标最有用）
scrcpy -s 127.0.0.1:5556 --no-audio

# 截图（不需要开窗口）
adb -s 127.0.0.1:5556 exec-out screencap -p > /tmp/ark.png

# 当前前台 Activity
adb -s 127.0.0.1:5556 shell dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'

# 游戏进程还在不在
adb -s 127.0.0.1:5556 shell pidof com.hypergryph.arknights

# logcat（反外挂 / 崩溃）
adb -s 127.0.0.1:5556 logcat -d -b all | grep -iE 'arknights|tprt|ace|GP7|ndk_translation|FATAL'
```

---

## 安全与隐私

- 本文所有路径用 `~/`，不包含用户名、手机号、游戏 UID、账号信息。
- 建议把端口绑到回环：`-p 127.0.0.1:5556:5555`。如果像本文一样用了 `-p 5556:5555`，ADB 会监听 `0.0.0.0`，同局域网的人可以连上来，**请用防火墙挡住 5555/5556**。
- 不要在任何文档、issue、截图里放 MAA 配置里的账号 token、验证码、游戏 ID。

---

## 相关链接

- MAA 仓库：<https://github.com/MaaAssistantArknights/MaaAssistantArknights>
- 本方案发过的 MAA issue 评论：
  - <https://github.com/MaaAssistantArknights/MaaAssistantArknights/issues/7127#issuecomment-6822547761>
  - <https://github.com/MaaAssistantArknights/MaaAssistantArknights/issues/12506#issuecomment-6822550241>
- ChromeOS libndk：<https://github.com/ilhan-athn7/android_proprietary_native_bridge/releases>
- redroid：<https://github.com/remote-android/redroid-doc>
- MAA 官网：<https://maa.plus/>

---

## 文档目录

| 文档 | 内容 |
|---|---|
| [docs/01-环境与容器.md](docs/01-环境与容器.md) | 前置检查、容器创建、APK 安装、分辨率、ARM 翻译层、持久化 |
| [docs/02-反外挂与指纹.md](docs/02-反外挂与指纹.md) | **核心根因**：fingerprint 超长 → TenProtect 杀进程，含取证过程 |
| [docs/03-网络与MTU.md](docs/03-网络与MTU.md) | MTU 1492 全链路对齐、PMTUD 黑洞、DNS 实测结论 |
| [docs/04-启动流程与坐标.md](docs/04-启动流程与坐标.md) | 冷启动状态机、金色菱形、开始唤醒、分辨率换算 |
| [docs/05-MAA接管.md](docs/05-MAA接管.md) | Lutris + Wine、adb.exe、MAA 配置、任务队列 |
| [docs/06-排错手册.md](docs/06-排错手册.md) | 症状 → 原因 → 验证命令 → 处理 |
| [docs/07-踩坑记录.md](docs/07-踩坑记录.md) | 走过的弯路，以及为什么那些方向是错的 |
| [scripts/start-arknights.sh](scripts/start-arknights.sh) | 一键：起容器 + 补网络/设置 + 校验 + 可选起游戏 |
| [scripts/fix-fingerprint.sh](scripts/fix-fingerprint.sh) | 修复指纹（**必做**），带备份、校验、重启 |
| [scripts/redroid-fix-mtu](scripts/redroid-fix-mtu) | 把 `podman0` 和容器 `eth0` 的 MTU 改成 1492 |

---

## 已知限制

- 无音频：redroid 默认不出声，MAA 也不需要声音。
- 首次登录必须手动：国服要手机号 + 短信验证码，MAA 做不了。登录态保存在 `/data`，容器重建不丢（只要 `~/redroid-arknights` 还在）。
- 游戏大版本更新要在容器里重新热更，网络必须通（见 03）。
- `/system` 的修改只存在于容器可写层：`podman restart` 保留，`podman rm` 重建就没了。重建后要重跑第 6、7 步，或者提前 `podman commit`（见 01 第 8 节）。
- 本文只覆盖 Android 11 镜像 + libndk v0.2.3 这一套组合。Android 13 镜像的库匹配关系不同，不在覆盖范围内。
