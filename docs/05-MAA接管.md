# 05 · MAA 接管：Lutris + Wine + adb.exe

## 1. 为什么要这么绕

MAA 官方只发 Windows 版（WPF / .NET）。Linux 上能用的路线有三条：

| 路线 | 可行性 | 说明 |
|---|---|---|
| **Windows MAA + Wine/Lutris** | ✅ 本文方案 | 功能完整，GUI 正常，已验证 |
| maa-cli（AUR） | ✅ 可用 | 命令行版，功能少一些，但更轻 |
| 安卓版 MAA | ⚠️ 不适合 | 需要另一台安卓设备，且不能控制容器 |

因为需求是「MAA 必须部署进 Lutris」，这里只讲第一条。maa-cli 作为备选放在最后。

MAA 控制游戏的原理很简单：调用 `adb.exe` 截图、发触摸事件。所以只要 Wine 里的 `adb.exe` 能连上 `127.0.0.1:5556`，剩下的事和真机没区别。

## 2. 下载与放置

### 2.1 MAA 完整包

从 [MAA Releases](https://github.com/MaaAssistantArknights/MaaAssistantArknights/releases) 下载 **完整包**（文件名类似 `MAA-v6.22.0-win-x64.zip`），不要下增量更新包。

解压到：

```
~/Games/MAA/
├── MAA.exe
├── MAA.dll
├── MaaCore.dll
├── resource/
├── platform-tools/     ← 下一步放
├── config/             ← 首次运行生成
├── data/
└── debug/
```

**必须完整解压。** 如果启动时弹「安装文件缺失，检测到 419 个文件缺失」，先别急着重下——很可能是**文件名乱码**，不是文件真的缺。看目录里有没有这种名字：

```
DependencySetup_ф╛Эш╡Цх║УхоЙшгЕ.bat
Res/Backgrounds/Wallpapers/чЙЫчЙЫшбицГЕхМЕ1/
resource/copilot/old/цЦ╜ф╜йх░Фх▒▒шДЪ_...
```

有的话，说明解压器把 ZIP 里的 UTF-8 文件名当成 CP866 解码了（Wine 里的更新器/解压工具常见）。文件内容是全的，只是名字坏了，MAA 对照 `filelist.txt` 找不到这些名字，就报「缺失」。

修复：

```bash
python3 scripts/fix-maa-filenames.py            # 先预览
python3 scripts/fix-maa-filenames.py --apply    # 实际重命名
```

脚本只改文件名，不动内容，最后会用 `filelist.txt` 校验，期望输出：

```
filelist 条目: 10239，缺失: 0
```

然后重启 MAA，日志里应该出现：

```
Integrity check passed, 9713 file(s) verified
```

这个弹窗本身可以点「暂不处理，继续启动」，不影响核心任务，但修好之后不会再烦你。

> MAA 是绿色版，配置存在程序目录的 `config/`（便携模式），不在 Wine 的 `AppData` 里。升级时把旧目录的 `config/`、`data/`、`debug/` 复制到新目录即可。

### 2.2 Windows platform-tools

下载 Google 的 [platform-tools for Windows](https://developer.android.com/tools/releases/platform-tools)，把 `adb.exe`、`AdbWinApi.dll`、`AdbWinUsbApi.dll` 放进：

```
~/Games/MAA/platform-tools/
```

只需要这三个文件，`fastboot.exe` 之类可以不要。

> 为什么不用 Linux 的 `adb`？MAA 通过 `Process.Start` 调 `AdbPath`，在 Wine 里启动 Linux 原生二进制不可靠。用 Windows 版 `adb.exe` 最稳。

## 3. 建 Wine 前缀

```bash
# 64 位前缀
WINEPREFIX=~/Games/maa-prefix WINEARCH=win64 wineboot -u
```

等它初始化完（会弹 Mono/Gecko 安装提示，可以取消，MAA 不需要）。

### 3.1 Wine 版本

实测可用：**dwproton-11.0-14**（日志里显示 `Running under Wine 11.0`）。Lutris 的 wine-ge 系列一般也能跑，但 .NET/WPF 的兼容性在不同版本间有差异，遇到白屏/闪退先换 Wine 版本。

安装 Lutris Wine 版本的常规方式：

```bash
# Lutris 自带 runner 管理，或在 GUI 里：首选项 → 运行器 → Wine → 下载
ls ~/.local/share/lutris/runners/wine/
```

### 3.2 VC++ 运行库

如果启动时报：

```
MaaCore.dll 加载失败
• 未安装 Microsoft Visual C++ V14 Redistributable (x64) 或版本过低
```

在同一个前缀里装运行库：

```bash
WINEPREFIX=~/Games/maa-prefix winetricks -q vcrun2022
```

或者运行 MAA 目录里的 `DependencySetup_依赖库安装.bat`（Wine 下可能弹 UAC，成功率不如 winetricks）。

装完再启动。**这一步不做，MAA 会在加载 `MaaCore.dll` 时直接退出。**

## 4. Lutris 条目

### 4.1 方式 A：直接放 YAML（推荐，可复制）

Lutris 的游戏条目就是 `~/.local/share/lutris/games/*.yml`。新建：

```yaml
# ~/.local/share/lutris/games/maa-1794300000.yml
game:
  exe: /home/<you>/Games/MAA/MAA.exe
  prefix: /home/<you>/Games/maa-prefix
  working_dir: /home/<you>/Games/MAA
game_slug: maa
name: MAA
system:
  disable_runtime: true
wine:
  version: dwproton-11.0-14
```

把 `<you>` 换成你的用户名，`version` 换成你实际装的 Wine runner 名称。

启动：

```bash
lutris lutris:rungameid/1794300000
# 或者按 slug
lutris lutris:rungame/maa
```

### 4.2 方式 B：GUI 添加

1. Lutris 左上角 `+` → 「添加本地游戏」；
2. 名称 `MAA`，运行器选 `Wine`；
3. 游戏选项：
   - 可执行文件：`~/Games/MAA/MAA.exe`
   - Wine 前缀：`~/Games/maa-prefix`
   - 工作目录：`~/Games/MAA`
4. 运行器选项 → Wine 版本：选实测可用的那个；
5. 系统选项 → 关闭 Lutris Runtime（`disable_runtime: true`）。

### 4.3 为什么 `disable_runtime: true`

Lutris 默认会套一层 runtime（容器化的库环境）。MAA 这种 .NET + 原生 DLL 混合的程序，套 runtime 后经常出现 `MaaCore.dll` 加载失败或 GPU 初始化失败。关掉后用系统库，实测正常。

## 5. 配置 MAA

第一次启动后，MAA 会在 `~/Games/MAA/config/gui.new.json` 写配置。

### 5.1 连接设置

GUI 路径：`设置` → `连接设置`。

| 项 | 值 |
|---|---|
| 连接方式 | ADB |
| ADB 路径 | `Z:\home\<you>\Games\MAA\platform-tools\adb.exe` |
| 连接地址 | `127.0.0.1:5556` |
| 触控模式 | `MiniTouch` |
| 退出时关闭 ADB | ❌ 关闭（`KillAdbOnExit: false`） |

Wine 里 `Z:` 映射到 Linux 的 `/`，所以路径是 `Z:\home\<you>\...`，不是 `C:\`。

对应的 JSON（MAA 关闭时会写回）：

```json
{
  "Configurations": {
    "Default": {
      "Gui": {
        "ConnectSettings": {
          "AdbPath": "Z:\\home\\<you>\\Games\\MAA\\platform-tools\\adb.exe",
          "Address": "127.0.0.1:5556",
          "TouchMode": "MiniTouch",
          "KillAdbOnExit": false
        },
        "RuntimeSettings": {
          "ClientType": "Official"
        }
      }
    }
  }
}
```

### 5.2 启动设置

- 客户端类型：**官服**（`Official`）；
- 账号切换：不用（只有一个账号）；
- 自动启动客户端：需要时勾上（MAA 会自己 `am start`）。

### 5.3 连接测试

点 MAA 的「截图测试」或直接点「开始」。正常表现：

- 标题栏显示 `官服` 和 `(5556)`；
- 能看到游戏画面截图；
- 日志里出现 `Connect` 成功、`AsstLoadResource ret: true`。

如果 MAA 同时看到 5555 和 5556（因为崩铁容器也在跑），**一定要在地址里写死 `127.0.0.1:5556`**，不要让它自动选。

### 5.4 adb.exe 与宿主机 adb server 的关系

Wine 和 Linux 共用同一个网络栈。所以：

- Wine 里的 `adb.exe` 启动 server 时，会尝试监听宿主机的 `5037`；
- 如果宿主机已经有 `adb` server 在跑（`adb devices` 能看到设备），Wine 里的 `adb.exe` 会直接复用这个 server；
- 两边协议版本不一致时，会报 `adb server version doesn't match`，此时在宿主执行一次 `adb kill-server`，让 MAA 重新拉起即可。

`KillAdbOnExit: false` 的作用：MAA 退出时不要把 server 杀掉，否则会顺带影响宿主机的 `adb`（以及另一个崩铁容器的连接）。

## 6. 任务队列

MAA 的默认任务队列已经够用，推荐顺序：

```
开始唤醒 (StartUp)
  → 刷理智 (Fight)
  → 自动公招 (Recruit)
  → 基建换班 (Infrast)
  → 领取信用及购物 (Mall)
  → 领取奖励 (Award)
  → 肉鸽（可选）
  → 生息演算（可选）
```

几个关键设置：

- **刷理智**：关卡填当前活动图或 `1-7`；「使用理智药」按需；「次数」留空表示刷到理智耗尽。
- **基建换班**：先跑一次「一键换班」确认布局能被识别；`DormThreshold` 默认 30。
- **自动公招**：确认标签识别正常，否则可能浪费加急许可。
- **开始唤醒**：客户端类型选官服；如果不勾「自动启动客户端」，需要游戏已经在前台。

第一次跑建议只开「开始唤醒」，确认能从任意界面进到主界面，再逐项加任务。

## 7. 日常启动流程

```bash
# 1) 容器（如果没在跑）
sudo podman start redroid-arknights

# 2) 等开机 + 补网络/设置（脚本会做）
scripts/start-arknights.sh

# 3) 起 MAA
lutris lutris:rungameid/1794300000

# 4) 在 MAA 里点「开始」
```

或者把 1–3 写成一个桌面快捷方式 / systemd user unit。MAA 自己会启动游戏（StartUp 任务），不需要提前 `am start`。

## 8. 常见问题

| 症状 | 原因 | 处理 |
|---|---|---|
| `MaaCore.dll 加载失败` | 缺 VC++ 运行库 / 解压不完整 | `winetricks -q vcrun2022`，重新完整解压 |
| 启动白屏 / 秒退 | Wine 版本不兼容 | 换 dwproton-11.0-14 或 wine-ge |
| 找不到 adb | `AdbPath` 写错 / 用了 Linux 路径 | 用 `Z:\...\adb.exe` |
| `adb server version doesn't match` | 宿主 adb server 版本旧 | 宿主 `adb kill-server`，重启 MAA |
| 设备列表有 5555 和 5556 | 崩铁容器也在跑 | 地址写死 `127.0.0.1:5556` |
| 截图全黑 | 屏幕休眠 / 分辨率不对 | `svc power stayon true`；确认 16:9 |
| 能截图但点不动 | 触控模式不对 | 换 `MiniTouch` / `MaaTouch` / `ADB` 逐个试 |
| 点开始后一直「连接中」 | 容器里游戏没起 / adb 掉线 | `adb devices`、`pidof`、看 MAA 日志 |
| 提示 419 个文件缺失 | 文件名被按 CP866 解码（不是真缺文件） | `python3 scripts/fix-maa-filenames.py --apply` |
| GPU 警告 `驱动信息无法读取` | Wine 读不到 AMD 驱动版本 | 可忽略，实测 OCR/推理正常 |
| MAA 更新失败 | `MAA.Updater.exe` 在 Wine 下不稳定 | 手动下载完整包，覆盖时保留 `config/` |

日志位置：

```
~/Games/MAA/debug/gui.log     # GUI / 连接 / 配置
~/Games/MAA/debug/asst.log    # 核心：识别、点击、任务
```

## 9. 备选：maa-cli

如果不需要 GUI，AUR 有 `maa-cli`：

```bash
yay -S maa-cli
```

配置 `~/.config/maa/asst.toml`：

```toml
[connection]
type = "ADB"
adb_path = "adb"          # 用宿主 Linux 的 adb 即可
device = "127.0.0.1:5556"

[instance_options]
touch_mode = "MiniTouch"
```

```bash
maa run cn_daily
```

它和 Wine 版共用同一套 MAA 核心，只是没有界面。适合塞进 cron / systemd timer。

> 注意：maa-cli 与 Wine 版**不要同时连同一个容器**。两个控制器同时截图、点击，会互相干扰。

## 10. 安全提醒

- MAA 配置里不要放账号密码；国服登录态在游戏容器里，MAA 不保存。
- 分享 `gui.new.json` / 日志前，先删掉 `AdbPath` 里的用户名、`Address` 里的内网 IP、以及任何 token。
- 不要把 5556 暴露到公网。ADB 没有认证，连上就能完全控制容器。
