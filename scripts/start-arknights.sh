#!/usr/bin/env bash
# 一键把 redroid-arknights 拉起来，并补齐容器重启后会丢的东西。
#
# 用法:
#   scripts/start-arknights.sh                # 起容器 + 补设置 + 体检
#   scripts/start-arknights.sh --launch       # 额外启动游戏（不自动点）
#   scripts/start-arknights.sh --auto-enter   # 启动并自动点菱形/开始唤醒（按屏幕比例）
#
# 环境变量:
#   NAME=redroid-arknights  PORT=5556  ADB=adb
#
# 注意: 默认用 rootful podman（自动判断是否需要 sudo）。

set -euo pipefail

NAME="${NAME:-redroid-arknights}"
PORT="${PORT:-5556}"
ADB="${ADB:-adb}"
SERIAL="127.0.0.1:${PORT}"
LAUNCH=0
AUTO_ENTER=0

for arg in "$@"; do
    case "$arg" in
        --launch) LAUNCH=1 ;;
        --auto-enter) LAUNCH=1; AUTO_ENTER=1 ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *)
            echo "未知参数: $arg" >&2
            exit 2
            ;;
    esac
done

# 目标容器可能在 rootful podman 里。先看 rootless，找不到就用 sudo。
SUDO=""
if ! podman container exists "$NAME" >/dev/null 2>&1; then
    SUDO="sudo"
fi

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

adb_do() { "$ADB" -s "$SERIAL" "$@"; }

# ---------- 1. 容器 ----------
say "检查容器 $NAME"
if ! $SUDO podman container exists "$NAME" >/dev/null 2>&1; then
    die "容器 $NAME 不存在。先按 docs/01-环境与容器.md 创建。"
fi

if [ "$($SUDO podman inspect -f '{{.State.Running}}' "$NAME")" != "true" ]; then
    say "启动容器"
    $SUDO podman start "$NAME" >/dev/null
else
    say "容器已在运行"
fi

# ---------- 2. ADB / 开机 ----------
say "连接 ADB $SERIAL"
"$ADB" connect "$SERIAL" >/dev/null 2>&1 || true

say "等待 sys.boot_completed=1（最多 90 秒）"
ok=0
for _ in $(seq 1 45); do
    state="$(adb_do shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    if [ "$state" = "1" ]; then ok=1; break; fi
    "$ADB" connect "$SERIAL" >/dev/null 2>&1 || true
    sleep 2
done
[ "$ok" = "1" ] || die "等不到开机完成。看 sudo podman logs --tail 100 $NAME"

# ---------- 3. 系统设置 ----------
say "补系统设置（private DNS / captive portal / 常亮 / 锁屏）"
adb_do shell settings put global private_dns_mode off >/dev/null 2>&1 || warn "private_dns_mode 设置失败"
adb_do shell settings put global captive_portal_mode 0 >/dev/null 2>&1 || warn "captive_portal_mode 设置失败"
adb_do shell svc power stayon true >/dev/null 2>&1 || warn "stayon 设置失败"
adb_do shell settings put system screen_off_timeout 2147483647 >/dev/null 2>&1 || true
adb_do shell locksettings set-disabled true >/dev/null 2>&1 || true
adb_do shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true

# ---------- 4. MTU ----------
say "修 MTU（podman0 + 容器 eth0 → 1492）"
MTU_SCRIPT=""
for candidate in /usr/local/sbin/redroid-fix-mtu "$(dirname "$0")/redroid-fix-mtu"; do
    if [ -x "$candidate" ]; then MTU_SCRIPT="$candidate"; break; fi
done
if [ -n "$MTU_SCRIPT" ]; then
    $SUDO "$MTU_SCRIPT" "$NAME" || warn "MTU 脚本失败，继续"
else
    warn "找不到 redroid-fix-mtu，手动改"
    $SUDO ip link set podman0 mtu 1492 2>/dev/null || true
    pid="$($SUDO podman inspect -f '{{.State.Pid}}' "$NAME")"
    [ "$pid" != "0" ] && $SUDO nsenter -t "$pid" -n ip link set eth0 mtu 1492 || true
fi

# ---------- 5. 体检 ----------
say "体检"
FP="$(adb_do shell getprop ro.build.fingerprint 2>/dev/null | tr -d '\r' || true)"
FP_LEN=${#FP}
if [ "$FP_LEN" -eq 0 ] || [ "$FP_LEN" -ge 92 ]; then
    warn "ro.build.fingerprint 长度=$FP_LEN（应为 90）→ 游戏会被 TenProtect 杀掉"
    warn "运行: scripts/fix-fingerprint.sh $SERIAL"
else
    say "fingerprint 长度=$FP_LEN ✓"
fi

BRIDGE_MD5="$(adb_do shell 'su 0 md5sum /system/lib64/libndk_translation.so' 2>/dev/null | awk '{print $1}' || true)"
if [ "$BRIDGE_MD5" = "0f8376da34ee3edd10e79105aec478f4" ]; then
    say "libndk v0.2.3 ✓"
else
    warn "libndk md5=${BRIDGE_MD5:-空}（期望 0f8376da34ee3edd10e79105aec478f4）"
fi

if adb_do shell 'su 0 test -e /system/lib64/arm64/libvulkan.so' >/dev/null 2>&1; then
    warn "guest libvulkan.so 仍然存在 → 启动会 SIGABRT"
    warn "运行: adb -s $SERIAL shell 'su 0 mv /system/lib64/arm64/libvulkan.so /system/lib64/arm64/libvulkan.so.disabled'"
else
    say "guest libvulkan 已禁用 ✓"
fi

if adb_do shell 'ping -c 1 -W 2 223.5.5.5' >/dev/null 2>&1; then
    say "容器网络 ✓"
else
    warn "容器 ping 不通 223.5.5.5（先确认宿主网络 / MTU）"
fi

SIZE="$(adb_do shell wm size 2>/dev/null | tr -d '\r' | tail -n1)"
DENSITY="$(adb_do shell wm density 2>/dev/null | tr -d '\r' | tail -n1)"
say "显示: ${SIZE:-未知} / ${DENSITY:-未知}"

# ---------- 6. 可选：起游戏 ----------
if [ "$LAUNCH" = "1" ]; then
    say "启动游戏"
    adb_do shell am start -W -n com.hypergryph.arknights/com.u8.sdk.U8UnityContext >/dev/null
fi

if [ "$AUTO_ENTER" = "1" ]; then
    # 从 wm size 解析宽高（取 Override 优先）
    read -r W H <<EOF
$(adb_do shell wm size 2>/dev/null | tr -d '\r' | awk -F'[:x]' '/Override/{print $2, $3}' | tail -n1)
EOF
    if [ -z "${W:-}" ] || [ -z "${H:-}" ]; then
        read -r W H <<EOF
$(adb_do shell wm size 2>/dev/null | tr -d '\r' | awk -F'[:x]' '/Physical/{print $2, $3}' | tail -n1)
EOF
    fi
    [ -n "${W:-}" ] && [ -n "${H:-}" ] || die "解析不到分辨率"

    DX=$(( W / 2 ))
    DY=$(( H * 911 / 1000 ))   # 金色菱形 ≈ 0.911 * 高度
    WX=$(( W / 2 ))
    WY=$(( H * 708 / 1000 ))   # 开始唤醒 ≈ 0.708 * 高度

    say "等待加载页 25 秒"
    sleep 25
    say "点金色菱形 ($DX,$DY)"
    adb_do shell input tap "$DX" "$DY" >/dev/null
    sleep 12
    say "点开始唤醒 ($WX,$WY)"
    adb_do shell input tap "$WX" "$WY" >/dev/null
    say "已发送。若未进主界面，截图确认: adb -s $SERIAL exec-out screencap -p > /tmp/ark.png"
fi

say "完成。串口 $SERIAL；MAA 地址填 127.0.0.1:$PORT"
