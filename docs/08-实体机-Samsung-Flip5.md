# 实体机部署：Samsung Galaxy Z Flip5 (SM-F7310)

这是一份**实体机 + Linux maa-cli** 的旁路部署记录，面向同机型（Samsung Galaxy Z Flip5 / SM-F7310）、**无 root** 的复现。本仓库主流程是 redroid；这篇记录的是把方舟从容器迁到实体机时做过的、重启后仍然生效的改动，以及 Linux 侧配套的持久化配置。

不包含账号、玩家 UID、设备序列号、局域网 IP、SMTP 授权码或任何登录凭据；需要填设备序列号的地方统一写成 `$DEVICE`。

> **2026-11-22 状态更新**：肉鸽等级已满，`maa-rogue.service` 已停用，`maa-rogue-stop.timer` 已 `disable`，`~/.cache/maa/rogue.enabled` 已删除，`maa-daily.service` 里的停肉鸽/续肉鸽钩子也已移除；手机所有可控音量已设为 0，勿扰为“无干扰”。下文的肉鸽定时和自动续跑是迁移时的配置，恢复肉鸽时需要按原样加回。

## 调试过程（按发现顺序）

1. **画面出现黑边**：一开始用 `wm size 1920x1080` 把 1080×1920 的面板改成横屏，结果安全区被钉在顶部，应用窗口变成 `[0,167][1920,1080]`。改回 `wm size reset` / `wm density reset` 后原生 1080p 满屏。
2. **长时间不动就黑屏**：`mWakefulness=Awake`、`mScreenState=ON`，但截图平均亮度从 182 掉到 18.7；后来在窗口列表里看到 `GameBooster Lock Screen`，确认是三星 Game Tools 的自动触摸锁，不是系统锁屏。`locksettings` 只能解决系统锁屏，解决不了它。
3. **MaaFwAdb 不可用**：Linux 预编译包的 `libMaaAdbControlUnit.so` 和 `libMaaUtils.so` 不同步，选 MaaFwAdb 会因 `ChildPipeIOStream::eof()` 未定义直接崩。改用 `MaaTouch`。
4. **`maa` CLI 跑完不退出**：任务日志已经 `AllTasksCompleted`，但进程卡在 `Assistant::~Assistant()` 的 `std::thread::join()`，导致每日脚本等不到退出、也不发邮件。最后把 `CloseDown` 从日常/肉鸽任务里去掉。
5. **肉鸽停后跑日常仍停在肉鸽界面**：MAA 的 `StartUp` 看到游戏已经启动，不会强制重启。改为在每日/肉鸽脚本启动前 `adb shell am force-stop com.hypergryph.arknights`，等 3 秒再让 MAA 拉起。
6. **Award / Depot 失败**：`OperProgress` 之后游戏停在干员页，`AwardBegin` 连试 20 次认不出。每日任务在 `Award` 前补一次 `StartUp` 回主界面。
7. **手机重启后 ADB 全断**：`adb devices` 看到 `no permissions`，不是手机端 USB 调试被关，而是宿主机 adb server 还拿着重启前的 USB 节点。`adb kill-server` + `adb start-server` 即可恢复；`phone-keepawake` 已加自动恢复逻辑，只在 `no permissions` 时重启 server。

## 重启验证（2026-11-22）

重启手机后逐项复查，以下都还在：

```text
wm size              1080x1920（无 override）
wm density           480
user_rotation        1（accelerometer_rotation=0）
screen_off_timeout   2147483647
stay_on_while_plugged_in 15
screen_brightness    0 / 手动
locksettings         true / lockscreen.disabled=1
Game Tools           disabled
game touch lock      0 / 0
OTA 两个包           disabled-user
ota_disable_automatic_update / galaxy_system_update_block = 1 / 1
勿扰                 ZEN_MODE_NO_INTERRUPTIONS
```

`svc power stayon true` 是运行时设置，重启后不保证保留；由 `stay_on_while_plugged_in` + `phone-keepawake` 兜底。

ADB 重启后出现过一次 `no permissions`，原因和修复见上面第 7 条。

## 设备

| 项 | 值 |
|---|---|
| 型号 | Samsung Galaxy Z Flip5 `SM-F7310` |
| Android | 14（SDK 34） |
| 主屏 | 1080 × 1920，density 480 |
| 形态 | 主板机/无头使用，不接物理按键和翻盖 |
| 游戏 | 明日方舟国服 2.7.91，资源已下载 |
| ADB | USB，序列号从 `adb devices` 取，本文用 `$DEVICE` 代替 |
| 启动方式 | Linux 主机上的 `maa-cli` + systemd，不使用手机上的 MAA |

## 先记住这几条

- **不要再 `wm size 1920x1080` / `wm density 1920x1080` 覆盖。** 覆盖会把安全区（挖孔 94 px + 状态栏 73 px = 167 px）钉在顶部，应用窗口变成 `[0,167][1920,1080]`，游戏出现黑边。
- 需要恢复时用 `wm size reset` 和 `wm density reset`，让系统回到物理 1080 × 1920。
- Linux 端用 `MaaTouch`，不要选 `MaaFwAdb`。当前预编译包里 `libMaaAdbControlUnit.so` 缺 `libMaaUtils.so` 的 `ChildPipeIOStream::eof()` 符号，一选就崩。
- `maa` CLI 在 `CloseDown` 后可能卡在 `Assistant::~Assistant()` 的 `std::thread::join()`，进程不退出，后续发信也不会执行。日常/肉鸽任务都不再用 `CloseDown` 收尾，统一在下一次启动前用 `adb shell am force-stop` 清掉。
- 不要把屏幕真正按灭（`KEYCODE_SLEEP` / Dozing）。真关屏后 `screencap` 只返回全黑图，MAA 无法工作；当前方案是亮度 0 + 常亮 + 锁屏禁用。

## 手机侧持久化改动

以下命令在 Linux 主机执行，`$DEVICE` 替换成本机序列号。

### 锁屏、屏保、误触

```bash
adb -s "$DEVICE" shell '
  locksettings set-disabled true
  settings put secure lockscreen.disabled 1
  settings put secure screensaver_enabled 0
  settings put secure screensaver_activate_on_sleep 0
  settings put system double_tap_to_sleep 0
  settings put system intelligent_sleep_mode 0
  settings put system screen_off_pocket 0
'
```

目的：

- `locksettings get-disabled` 为 `true`，系统锁屏被禁用；
- 不再出现屏保/白日梦；
- 关掉双击熄屏、智能休眠、放口袋熄屏，避免主板机误判。

### 常亮与亮度

```bash
adb -s "$DEVICE" shell '
  settings put system screen_off_timeout 2147483647
  settings put global stay_on_while_plugged_in 15
  settings put system screen_brightness 0
  settings put system screen_brightness_mode 0
  svc power stayon true
'
```

说明：

- `screen_off_timeout=2147483647` 约 24.8 天；三星设置界面最高只显示 10 分钟，这是 UI 取整，不是实际值；
- `stay_on_while_plugged_in=15` 覆盖 AC/USB/无线/底座；
- `svc power stayon true` 是运行时命令，重启后不保证保留；主机侧 `phone-keepawake.timer` 每 5 分钟兜底；
- `screen_brightness=0` 让面板尽量不发光，但**截图仍然正常**，不同于真正关屏；
- `screen_brightness_mode=0` 固定手动亮度，避免自动亮度把画面改来改去。

### 分辨率与旋转

```bash
adb -s "$DEVICE" shell '
  wm size reset
  wm density reset
  settings put system accelerometer_rotation 0
  settings put system user_rotation 1
'
```

校验：

```bash
adb -s "$DEVICE" shell 'wm size; wm density; settings get system user_rotation; settings get system accelerometer_rotation'
# Physical size: 1080x1920
# Physical density: 480
# 1
# 0
```

注意：`user_rotation` / `accelerometer_rotation` 在回到桌面等场景可能被系统改回去；游戏自身会锁横屏，MAA 运行时通常不受影响。关键是**不要保留 `wm size` 覆盖**。

### 禁用系统更新（国行）

国行三星的系统更新由 `com.wssyncmldm` 和 `com.sec.android.soagent` 负责；直接停用这两个包，再落两个全局开关。**不需要 root**：

```bash
adb -s "$DEVICE" shell '
  settings put global ota_disable_automatic_update 1
  settings put global galaxy_system_update_block 1
  pm disable-user --user 0 com.wssyncmldm
  pm disable-user --user 0 com.sec.android.soagent
'
```

校验：

```bash
adb -s "$DEVICE" shell '
  for p in com.wssyncmldm com.sec.android.soagent com.samsung.android.fotaprovider com.samsung.android.sdm.config; do
    printf "%-38s " "$p"
    if pm list packages "$p" 2>/dev/null | grep -q "$p"; then
      dumpsys package "$p" | grep -m1 -oE "enabled=[0-9]+"
    else
      echo "未安装"
    fi
  done
  echo "ota_disable_automatic_update=$(settings get global ota_disable_automatic_update)"
  echo "galaxy_system_update_block=$(settings get global galaxy_system_update_block)"
'
```

预期：

```text
com.wssyncmldm          enabled=3
com.sec.android.soagent enabled=3
com.samsung.android.fotaprovider 未安装
com.samsung.android.sdm.config   未安装
ota_disable_automatic_update=1
galaxy_system_update_block=1
```

说明：

- `enabled=3` 是 `DISABLED_USER`，重启后仍然有效；系统 OTA / 恢复出厂可能重新启用，换机后重新执行即可。
- 这两个包只管系统更新，不影响游戏、ADB、MAA。
- 没有禁用 Galaxy Store（`com.sec.android.app.samsungapps`）；它管应用更新，不是系统 OTA。如果连应用自动更新也不想要，需要另外在 Galaxy Store 设置里关。

### 禁用三星 Game Tools 的自动触摸锁

这是之前“长时间不动就黑屏/锁屏”的真正原因：不是系统锁屏，是 `com.samsung.android.game.gametools` 的 `GameBooster Lock Screen` 覆盖层。

```bash
adb -s "$DEVICE" shell '
  settings put secure game_touchscreen_lock 0
  settings put secure game_edgescreen_touch_lock 0
  pm disable-user --user 0 com.samsung.android.game.gametools
'
```

校验：

```bash
adb -s "$DEVICE" shell 'settings get secure game_touchscreen_lock; settings get secure game_edgescreen_touch_lock'
# 0
# 0
adb -s "$DEVICE" shell 'pm list packages -d | grep gametools'
# package:com.samsung.android.game.gametools
```

说明：

- `pm disable-user` 写进用户包限制，重启后仍有效；系统 OTA 或恢复出厂可能重新启用；
- 禁用包时 `com.samsung.android.game.gos` 会把正在运行的游戏 force-stop 一次，这是包状态变化触发的一次性副作用，不是每次启动都会发生；
- 如果以后重新启用 Game Tools，自动触摸锁可能回来；主机侧 `phone-keepawake` 里保留了检测 `GameBooster Lock Screen` 并上滑解锁的兜底。
- 恢复 Game Tools：

```bash
adb -s "$DEVICE" shell pm enable com.samsung.android.game.gametools
```

### 复核命令

```bash
adb -s "$DEVICE" shell '
  echo "size=$(wm size | tr "\n" " ")"
  echo "density=$(wm density | tr "\n" " ")"
  echo "rotation=$(settings get system user_rotation)/$(settings get system accelerometer_rotation)"
  echo "timeout=$(settings get system screen_off_timeout)"
  echo "stayon=$(settings get global stay_on_while_plugged_in)"
  echo "brightness=$(settings get system screen_brightness)/$(settings get system screen_brightness_mode)"
  echo "lockscreen=$(locksettings get-disabled)/$(settings get secure lockscreen.disabled)"
  echo "screensaver=$(settings get secure screensaver_enabled)/$(settings get secure screensaver_activate_on_sleep)"
  echo "doubletap=$(settings get system double_tap_to_sleep)"
  echo "smart=$(settings get system intelligent_sleep_mode)"
  echo "pocket=$(settings get system screen_off_pocket)"
  echo "gametools_disabled=$(pm list packages -d | grep -c gametools)"
  echo "touchlock=$(settings get secure game_touchscreen_lock)/$(settings get secure game_edgescreen_touch_lock)"
  echo "wake=$(dumpsys power | grep -m1 -oE "mWakefulness=[A-Za-z]+")"
'
```

## Linux 侧持久化改动

### MAA 配置

`~/.config/maa/profiles/default.json`：

```json
{
  "connection": {
    "preset": "ADB",
    "adb_path": "/home/<user>/.local/bin/adb-maa",
    "address": "<DEVICE>",
    "config": "General"
  },
  "instance_options": {
    "touch_mode": "MaaTouch",
    "deployment_with_pause": false,
    "adb_lite_enabled": false,
    "kill_adb_on_exit": false
  }
}
```

要点：

- `adb_path` 必须走 `adb-maa`，不能用 `/usr/bin/adb`；
- `address` 用 USB 序列号，不用旧的 `127.0.0.1:5556`；
- `touch_mode` 用 `MaaTouch`；
- MAA 连接时自动测速，当前选中的是 `RawWithGzip`。

### `adb-maa`：剥掉多显示器警告

Flip5 有主屏和外屏两个 display。Android 14 的 `screencap` 在未指定 display id 时，会把下面这段警告写到 **stdout**，把 PNG/gzip 流顶掉：

```text
[Warning] Multiple displays were found, but no display id was specified! ...
```

MAA 直接解析 stdout 就会失败。包装器只在命令包含 `screencap` 时介入，从数据里找 PNG (`89 50 4E 47`) 或 gzip (`1F 8B`) 魔数，截掉前面的警告；其他命令原样透传给 `/usr/bin/adb`。

```bash
#!/usr/bin/env bash
set -u
REAL_ADB=/usr/bin/adb

want=0
for a in "$@"; do
    case "$a" in
        *screencap*) want=1 ;;
    esac
done

[ "$want" = 0 ] && exec "$REAL_ADB" "$@"

"$REAL_ADB" "$@" | python3 -c '
import sys
data = sys.stdin.buffer.read()
if data[:1] != b"[":
    sys.stdout.buffer.write(data)
    raise SystemExit(0)
marks = [i for i in (data.find(b"\x89PNG"), data.find(b"\x1f\x8b")) if i >= 0]
sys.stdout.buffer.write(data[min(marks):] if marks else data)
'
```

实际文件在 `~/.local/bin/adb-maa`。

### `phone-keepawake`：5 分钟保活

```bash
#!/usr/bin/env bash
set -u

ADB=${ADB:-/usr/bin/adb}
DEV=${1:-"${DEVICE:-}"}
[ -n "$DEV" ] || exit 0

"$ADB" -s "$DEV" get-state >/dev/null 2>&1 || {
    # 手机重启后，宿主机 adb server 可能还拿着旧的 USB 节点，报 no permissions。
    # 只在这种情况下重启 server，避免平时误伤 redroid。
    if "$ADB" devices 2>/dev/null | grep -qE "^${DEV}[[:space:]]+no permissions"; then
        "$ADB" kill-server >/dev/null 2>&1
        "$ADB" start-server >/dev/null 2>&1
        sleep 2
    fi
    "$ADB" -s "$DEV" get-state >/dev/null 2>&1 || exit 0
}

state=$("$ADB" -s "$DEV" shell dumpsys power 2>/dev/null \
        | grep -m1 -oE 'mWakefulness=[A-Za-z]+' | cut -d= -f2)

if [ "$state" != "Awake" ]; then
    "$ADB" -s "$DEV" shell input keyevent 224 >/dev/null 2>&1
    sleep 1
fi

# Game Tools 更新后如果重新启用，自动触摸锁会盖一层可拖动的锁屏
if "$ADB" -s "$DEV" shell dumpsys window windows 2>/dev/null \
        | grep -q 'GameBooster Lock Screen'; then
    "$ADB" -s "$DEV" shell input swipe 960 630 960 180 300 >/dev/null 2>&1
    sleep 1
fi

"$ADB" -s "$DEV" shell wm dismiss-keyguard >/dev/null 2>&1
```

### systemd 单元

`~/.config/systemd/user/phone-keepawake.service`：

```ini
[Unit]
Description=手机挂机保活（屏幕睡了就唤醒）

[Service]
Type=oneshot
ExecStart=%h/.local/bin/phone-keepawake <DEVICE>
```

`~/.config/systemd/user/phone-keepawake.timer`：

```ini
[Unit]
Description=每 5 分钟检查一次手机是否睡着

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
```

`~/.config/systemd/user/maa-daily.service`：

```ini
[Unit]
Description=MAA 每日任务（扫仓库 → 库存保持 → 理智作战 → 基建/公招/信用/培养/奖励）
After=network.target

[Service]
Type=oneshot
# 每日任务期间让肉鸽挂机让路
ExecStartPre=-/usr/bin/systemctl --user stop maa-rogue.service
# 先确保屏幕是亮的
ExecStartPre=-%h/.local/bin/phone-keepawake <DEVICE>
ExecStartPre=-/usr/bin/timeout 20 /usr/bin/adb -s <DEVICE> wait-for-device
# 强制冷启动：不能复用肉鸽/战斗界面
ExecStartPre=-/usr/bin/adb -s <DEVICE> shell am force-stop com.hypergryph.arknights
ExecStartPre=-/usr/bin/sleep 3
ExecStart=%h/.local/bin/maa-daily.py
# 跑完自动续肉鸽（存在开关文件才续）
ExecStopPost=-/usr/bin/bash -c 'test -f "%h/.cache/maa/rogue.enabled" && exec /usr/bin/systemctl --user start maa-rogue.service'
TimeoutStartSec=8h
```

`~/.config/systemd/user/maa-daily.timer`：

```ini
[Unit]
Description=每天 04:05 / 16:05 跑 MAA 每日任务

[Timer]
OnCalendar=*-*-* 04:05:00
OnCalendar=*-*-* 16:05:00
Persistent=true
AccuracySec=1s
Unit=maa-daily.service

[Install]
WantedBy=timers.target
```

`~/.config/systemd/user/maa-rogue.service`：

```ini
[Unit]
Description=MAA 肉鸽挂机（黑流树海 9999 局）
After=network.target
StartLimitIntervalSec=3600
StartLimitBurst=3

[Service]
Type=oneshot
ExecStartPre=-%h/.local/bin/phone-keepawake <DEVICE>
ExecStartPre=-/usr/bin/timeout 20 /usr/bin/adb -s <DEVICE> wait-for-device
ExecStart=%h/.local/bin/maa-run.py _rogue_9999
# 被 timer / 每日任务 SIGTERM 停止算正常结束
SuccessExitStatus=SIGTERM
Restart=on-failure
RestartSec=60
TimeoutStartSec=infinity
TimeoutStopSec=30
```

`~/.config/systemd/user/maa-rogue-stop.timer`：

```ini
[Unit]
Description=每天在 04:05 / 16:05 每日任务前暂停肉鸽

[Timer]
OnCalendar=*-*-* 03:55:00
OnCalendar=*-*-* 15:55:00
AccuracySec=1s
Unit=maa-rogue-stop.service

[Install]
WantedBy=timers.target
```

`~/.config/systemd/user/maa-rogue-stop.service`：

```ini
[Unit]
Description=每日任务前暂停肉鸽挂机

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl --user stop maa-rogue.service
```

> 实际文件用绝对路径；上面用 `%h` 是为了不把用户名写进仓库。`<DEVICE>` 替换成真实序列号。

启用：

```bash
systemctl --user enable --now phone-keepawake.timer
systemctl --user enable --now maa-daily.timer
systemctl --user enable --now maa-rogue-stop.timer
```

## 脚本行为

### 启动前强制重启

`~/.local/bin/maa-depot.py` 新增：

```python
def restart_game() -> None:
    ensure_device()
    subprocess.run(
        [ADB, "-s", ADDRESS, "shell", "am", "force-stop", "com.hypergryph.arknights"],
        capture_output=True, text=True, timeout=20,
    )
    time.sleep(3)
```

调用位置：

- `maa-daily.py`：实际跑每日前先 `restart_game()`，再扫仓库或执行缓存里的任务；
- `maa-run.py`：启动任何任务（包括肉鸽）前先 `restart_game()`；
- `maa-daily.service` 里也保留了 `am force-stop`，作为 systemd 层的第二道保险。

这样肉鸽在 03:55 被停、04:05 跑日历时，不会把游戏留在肉鸽/战斗界面；`StartUp` 一定是从干净状态重新拉起。

### 不把 Send/Close 放进 MAA 任务

`maa-daily.py` 生成的 `_daily.toml`：

- 开头 `StartUp`；
- `Award` 前再插一次 `StartUp`，避免 `OperProgress` 之后停在干员页导致 `AwardBegin` 认不出；
- 末尾**不生成 `CloseDown`**；
- 下次运行前由 `maa-daily.py` / systemd 的 `am force-stop` 清游戏。

`_rogue_9999.toml` 也不再用 `CloseDown` 收尾。原因同上：`maa` 在 `CloseDown` 后可能卡在 MaaCore 析构，导致不发邮件。

### 定时

| 时间 | 动作 |
|---|---|
| 03:55 / 15:55 | `maa-rogue-stop.timer` 停肉鸽 |
| 04:05 / 16:05 | `maa-daily.timer` 跑每日 |
| 每日结束后 | 存在 `~/.cache/maa/rogue.enabled` 时自动启动肉鸽 |
| 每 5 分钟 | `phone-keepawake.timer` 检查屏幕是否醒着 |

`~/.cache/maa/rogue.enabled` 是“是否自动续肉鸽”的开关；删掉它就不会自动续。

## 迁移时做过的清理

- `redroid-arknights` 容器停止并 `systemctl disable`，方舟改到实体机；崩铁容器 `redroid-starrail` 保持不变。
- 旧的 MAA 配置 `127.0.0.1:5556` 改成手机 USB 序列号，`adb` 路径改成 `adb-maa`。
- `redroid-arknights` 的服务文件保留，需要回滚时再启用。
- 没有把手机上的 ADB 无线端口持久化；当前使用 USB 序列号。

## 回滚

### 恢复 Game Tools

```bash
adb -s "$DEVICE" shell pm enable com.samsung.android.game.gametools
```

Game Tools 的自动触摸锁可能随包恢复；如果不想再看到 GameBooster Lock Screen，重新执行本文的禁用命令即可。

### 恢复系统锁屏/常亮

```bash
adb -s "$DEVICE" shell '
  locksettings set-disabled false
  settings put secure lockscreen.disabled 0
  settings put system screen_off_timeout 600000
  settings put global stay_on_while_plugged_in 0
  svc power stayon false
'
```

### 回到容器

1. `systemctl --user disable --now maa-daily.timer maa-rogue-stop.timer`
2. 停 `maa-rogue.service`
3. 恢复 `~/.config/maa/profiles/default.json` 的旧地址和 `/usr/bin/adb`
4. `sudo systemctl enable --now redroid-arknights.service`

## 已知问题

- **MaaFwAdb** 在 Linux 预编译包里不可用：加载 `libMaaAdbControlUnit.so` 时报 `undefined symbol _ZNK5MaaNS17ChildPipeIOStream3eofEv`，直接退出。不要修这个链接，使用 `MaaTouch`。
- **MaaCore 析构卡死**：`maa` 在 `CloseDown` 收尾后可能卡在 `Assistant::~Assistant()` 的 `std::thread::join()`，进程不退出，邮件也不会发。当前通过“任务不生成 `CloseDown` + 启动前 adb force-stop”规避。
- **三星 Game Tools**：`GameBooster Lock Screen` 不是系统锁屏；只禁用 `locksettings` 不够。当前直接 `pm disable-user` 整个 Game Tools。
- **真关屏不可用**：Dozing 后 `screencap` 只有全黑图；只能亮度 0 + 常亮。
- **`wm size` 覆盖会产生黑边**：千万不要用 `wm size 1920x1080` 解决分辨率问题。
- **`user_rotation` 可能被系统改回**：游戏会自己锁横屏，MAA 通常不受影响；如果异常，重新写入 `accelerometer_rotation=0` / `user_rotation=1`。
