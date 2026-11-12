#!/usr/bin/env bash
# 修复 redroid 上超长的 ro.build.fingerprint（TenProtect 杀进程的根因）。
#
# 用法:
#   scripts/fix-fingerprint.sh                       # 默认 127.0.0.1:5556 / redroid-arknights
#   scripts/fix-fingerprint.sh 127.0.0.1:5556
#   scripts/fix-fingerprint.sh --serial 127.0.0.1:5556 --container redroid-arknights
#   scripts/fix-fingerprint.sh --no-reboot           # 只改文件，不重启
#
# 原理: /system/build.prop 里显式设置 ro.build.fingerprint 后，init 不再用
#       ro.product.* / ro.build.* 拼那个 102 字符的超长值。
#
# 改完必须重启（容器 restart 或 adb reboot）才生效。

set -euo pipefail

SERIAL="127.0.0.1:5556"
NAME="redroid-arknights"
ADB="${ADB:-adb}"
REBOOT=1

# 90 字符，复用镜像里 ro.system.build.fingerprint 的合法值
FP="redroid/redroid_x86_64/redroid_x86_64:11/RD2A.211001.002/frank05271438:userdebug/test-keys"
FP_LINE="ro.build.fingerprint=${FP}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --serial) SERIAL="$2"; shift 2 ;;
        --container) NAME="$2"; shift 2 ;;
        --no-reboot) REBOOT=0; shift ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        -*) echo "未知参数: $1" >&2; exit 2 ;;
        *) SERIAL="$1"; shift ;;
    esac
done

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

adb_do() { "$ADB" -s "$SERIAL" "$@"; }

say "连接 $SERIAL"
"$ADB" connect "$SERIAL" >/dev/null 2>&1 || true
adb_do shell 'su 0 id' >/dev/null 2>&1 || die "连不上或没有 root。先在容器里确认 su 0 可用。"

BEFORE="$(adb_do shell getprop ro.build.fingerprint 2>/dev/null | tr -d '\r' || true)"
say "当前指纹长度: ${#BEFORE}"
[ -n "$BEFORE" ] && say "当前值: $BEFORE"

say "备份 /system/build.prop → /system/build.prop.orig（只备份一次）"
adb_do shell "su 0 sh -c '
  [ -f /system/build.prop.orig ] || cp /system/build.prop /system/build.prop.orig
'" >/dev/null

say "写入 90 字符指纹"
adb_do shell "su 0 sh -c '
  if grep -q \"^ro.build.fingerprint=\" /system/build.prop; then
    sed -i \"s|^ro.build.fingerprint=.*|${FP_LINE}|\" /system/build.prop
  else
    echo \"${FP_LINE}\" >> /system/build.prop
  fi
  chown 0:0 /system/build.prop
  chmod 644 /system/build.prop
  sync
'" >/dev/null

say "文件内容确认"
adb_do shell 'su 0 grep -n "^ro.build.fingerprint=" /system/build.prop'

COUNT="$(adb_do shell 'su 0 grep -c "^ro.build.fingerprint=" /system/build.prop' 2>/dev/null | tr -d '\r')"
[ "$COUNT" = "1" ] || warn "build.prop 里有 $COUNT 条 ro.build.fingerprint，建议手动清理重复项"

if [ "$REBOOT" = "0" ]; then
    say "--no-reboot：文件已改，重启后生效"
    exit 0
fi

# ---------- 重启 ----------
SUDO=""
CONTAINER_OK=0
if podman container exists "$NAME" >/dev/null 2>&1; then
    CONTAINER_OK=1
elif sudo podman container exists "$NAME" >/dev/null 2>&1; then
    SUDO="sudo"
    CONTAINER_OK=1
fi

if [ "$CONTAINER_OK" = "1" ]; then
    say "podman restart $NAME"
    $SUDO podman restart "$NAME" >/dev/null
else
    say "容器 $NAME 不存在，改用 adb reboot"
    adb_do reboot >/dev/null 2>&1 || true
fi

say "等待重启完成（最多 120 秒）"
"$ADB" connect "$SERIAL" >/dev/null 2>&1 || true
ok=0
for _ in $(seq 1 60); do
    state="$(adb_do shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    if [ "$state" = "1" ]; then ok=1; break; fi
    "$ADB" connect "$SERIAL" >/dev/null 2>&1 || true
    sleep 2
done
[ "$ok" = "1" ] || die "重启后等不到开机完成，检查容器状态"

AFTER="$(adb_do shell getprop ro.build.fingerprint 2>/dev/null | tr -d '\r' || true)"
say "重启后长度: ${#AFTER}"
say "重启后值: $AFTER"

if [ "${#AFTER}" -le 91 ] && [ "${#AFTER}" -gt 0 ]; then
    say "修复成功 ✓"
else
    die "仍然不对（长度 ${#AFTER}）。检查 /system/build.prop 是否被覆盖，或是否有多条。"
fi

say "补系统设置（重启会丢）"
adb_do shell settings put global private_dns_mode off >/dev/null 2>&1 || true
adb_do shell settings put global captive_portal_mode 0 >/dev/null 2>&1 || true
adb_do shell svc power stayon true >/dev/null 2>&1 || true

warn "别忘了跑: sudo /usr/local/sbin/redroid-fix-mtu $NAME"
