#!/usr/bin/env bash
# 找回 MAA/Wine 的弹窗：把 MAA 进程的所有顶层窗口列出来，并把跑到屏幕外/被挡住的
# 窗口移回屏幕中央、置顶、激活。
#
# 用法:
#   scripts/rescue-maa-windows.sh          # 直接抢救
#   scripts/rescue-maa-windows.sh --list   # 只列出窗口，不动
#
# 建议在 KDE 里绑一个快捷键（例如 Meta+Shift+M）指向本脚本。

set -u

LIST_ONLY=0
[ "${1:-}" = "--list" ] && LIST_ONLY=1

command -v xdotool >/dev/null 2>&1 || { echo "需要 xdotool: sudo pacman -S xdotool" >&2; exit 1; }

MAA_PATTERN="${MAA_PATTERN:-MAA\.exe}"
pids=$(pgrep -f "$MAA_PATTERN" 2>/dev/null || true)
if [ -z "$pids" ]; then
    echo "没找到 MAA.exe 进程" >&2
    exit 1
fi

# 屏幕尺寸
screen=$(xdpyinfo 2>/dev/null | awk '/dimensions:/{print $2; exit}')
sw=${screen%x*}
sh=${screen#*x}
[ -n "$sw" ] && [ -n "$sh" ] || { sw=1920; sh=1080; }

# 收集 MAA 进程的窗口，去重并按窗口 id 排序（后创建的弹窗在后面，最后置顶）
mapfile -t ids < <(
    for p in $pids; do xdotool search --pid "$p" 2>/dev/null; done \
        | sort -n -u
)

if [ "${#ids[@]}" -eq 0 ]; then
    echo "MAA 进程在，但没有找到 X11 窗口（可能在 Wayland 原生窗口里？）" >&2
    exit 1
fi

skip_title() {
    case "$1" in
        ToastWindow|"Hidden Window"|"Default IME"|.NET-BroadcastEventWindow*|SystemResourceNotifyWindow|MediaContextNotificationWindow) return 0 ;;
        *adb.exe) return 0 ;;
    esac
    return 1
}

echo "屏幕 ${sw}x${sh}，MAA PID: $(echo "$pids" | tr '\n' ' ')"
candidates=()
for id in "${ids[@]}"; do
    name=$(xdotool getwindowname "$id" 2>/dev/null || true)
    eval "$(xdotool getwindowgeometry --shell "$id" 2>/dev/null || echo 'X=0 Y=0 WIDTH=0 HEIGHT=0')"
    [ "${WIDTH:-0}" -le 2 ] && continue
    [ "${HEIGHT:-0}" -le 2 ] && continue
    skip_title "$name" && continue

    state=$(xprop -id "$id" _NET_WM_STATE 2>/dev/null || true)
    trans=$(xprop -id "$id" WM_TRANSIENT_FOR 2>/dev/null || true)
    kind="normal"
    if [[ "$state" == *MODAL* ]] || [[ "$trans" == *"window id"* ]]; then
        kind="dialog"
    fi

    printf '  [%s] %sx%s @ %s,%s  %s  (%s)\n' "$id" "$WIDTH" "$HEIGHT" "$X" "$Y" "$name" "$kind"
    candidates+=("$id")
done

if [ "${#candidates[@]}" -eq 0 ]; then
    echo "没有可操作的顶层窗口。完整窗口列表："
    for id in "${ids[@]}"; do
        echo "  [$id] $(xdotool getwindowname "$id" 2>/dev/null) $(xdotool getwindowgeometry --shell "$id" 2>/dev/null | tr '\n' ' ')"
    done
    exit 0
fi

[ "$LIST_ONLY" = "1" ] && exit 0

for id in "${candidates[@]}"; do
    eval "$(xdotool getwindowgeometry --shell "$id" 2>/dev/null || echo 'X=0 Y=0 WIDTH=0 HEIGHT=0')"
    [ "${WIDTH:-0}" -gt 0 ] || continue

    # 完全在屏幕外，或尺寸超出屏幕：移回可见区域
    if [ "$X" -lt 0 ] || [ "$Y" -lt 0 ] || [ $((X + WIDTH)) -gt "$sw" ] || [ $((Y + HEIGHT)) -gt "$sh" ]; then
        nx=$(( (sw - WIDTH) / 2 ))
        ny=$(( (sh - HEIGHT) / 2 ))
        [ "$nx" -lt 0 ] && nx=0
        [ "$ny" -lt 0 ] && ny=0
        xdotool windowmove "$id" "$nx" "$ny" 2>/dev/null || true
        echo "移动 [$id] -> ${nx},${ny}"
    fi

    # 拉到当前桌面，取消最小化，置顶并激活
    cur=$(xdotool get_desktop 2>/dev/null || echo 0)
    xdotool set_desktop_for_window "$id" "$cur" 2>/dev/null || true
    xdotool windowmap "$id" 2>/dev/null || true
    xdotool windowraise "$id" 2>/dev/null || true
    xdotool windowactivate "$id" 2>/dev/null || true
    sleep 0.15
done

echo "完成。最后激活的窗口应该是 MAA 的弹窗；如果还看不到，跑 --list 看几何信息。"
