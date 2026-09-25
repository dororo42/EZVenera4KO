#!/bin/bash
# EZVenera for KOReader — 真机导航验证一键脚本（审查报告 §10 验收清单）
# 用法: scripts/device-test-nav.sh [设备序列号 | IP:5555]
# 前提: adb 在 PATH（本机可用 scrcpy 自带的，用 ADB= 覆盖），设备已授权
# 流程: 推送插件 → 重启 KOReader → logcat 落盘 → 截图存证
# 说明: 本设备 input tap 坐标不可靠（交接记录），走查点击由用户手点，
#       脚本在每步之间自动截图；logcat 全程落盘供事后核对。

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$ROOT/src/koreader-plugin/ezvenera.koplugin"
PKG="org.koreader.launcher.fdroid"
OUT="$ROOT/logs/device-nav-test-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

ADB="${ADB:-adb}"
DEV="${1:-}"
d() { if [ -n "$DEV" ]; then "$ADB" -s "$DEV" "$@"; else "$ADB" "$@"; fi; }

echo "== 1/6 设备确认 =="
d wait-for-device
MODEL=$(d shell getprop ro.product.model)
VER=$(d shell getprop ro.build.version.release)
ABI=$(d shell getprop ro.product.cpu.abi)
echo "设备: $MODEL / Android $VER / $ABI"
if ! d shell pm list packages 2>/dev/null | grep -q "$PKG"; then
    echo "[err] 未找到 KOReader（$PKG）——确认这是测试平板？" >&2
    exit 1
fi

echo "== 2/6 推送插件（仅覆盖 ezvenera.koplugin）=="
d shell mkdir -p /sdcard/koreader/plugins
d push "$PLUGIN" /sdcard/koreader/plugins/ | tail -2
d shell "ls /sdcard/koreader/plugins/ezvenera.koplugin/browser.lua && echo PUSH-OK"

echo "== 3/6 重启 KOReader（logcat 全程落盘）=="
d logcat -c 2>/dev/null
d logcat -v time > "$OUT/logcat.log" 2>&1 &
LOGPID=$!
d shell am force-stop "$PKG" 2>/dev/null
sleep 2
d shell am start -n "$PKG"/.activities.FileManagerActivity 2>/dev/null \
    || d shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1
sleep 8
NEWPID=$(d shell pidof "$PKG" | tr -d '\r')
echo "KOReader PID: $NEWPID"
grep -c "luajit\|koreader" "$OUT/logcat.log" 2>/dev/null | head -1

shot() {  # $1 = 文件名
    d shell screencap -p /sdcard/ezv_nav_shot.png
    d pull /sdcard/ezv_nav_shot.png "$OUT/shots/$1.png" >/dev/null
    echo "  截图: $OUT/shots/$1.png"
}
mkdir -p "$OUT/shots"
shot 01-启动后首页

echo "== 4/6 加载健康检查（logcat 关键行）=="
grep -iE "ezvenera|luajit|error|exception|tombstone|FATAL" "$OUT/logcat.log" \
    | grep -v "chatty" | tail -30 | tee "$OUT/health.txt" || true
if grep -qiE "FATAL|tombstone" "$OUT/health.txt"; then
    echo "[warn] 检测到崩溃信号，优先看 $OUT/logcat.log"
fi

echo "== 5/6 手动走查（每步点完后回车截图存证）=="
cat <<'EOF'
请在平板上依次操作（每步完成后回到本窗口按回车）:
  a. 打开 KOReader 菜单 → 工具 → EZVenera 漫画
  b. 点「浏览漫画源」→ 进入源列表  （应看到标题栏左侧 ← 返回箭头）
  c. 点任一源 → 源主页             （面包屑=源名；← 应回到源列表）
  d. 点 ← 验证回到源列表
  e. 再进源主页 → 搜索/分类 → 结果 → 详情 → 章节 → 阅读
  f. 阅读中按系统返回键 → 应回到章节列表（不退出插件）
EOF
for step in a b c d e f; do
    read -r -p "步骤 $step 完成，回车截图… " _
    shot "manual-$step"
done

echo "== 6/6 收尾 =="
kill "$LOGPID" 2>/dev/null
grep -iE "FATAL|tombstone|luajit.*error" "$OUT/logcat.log" | tail -10 \
    > "$OUT/final-check.txt" || true
echo "[ok] 证据齐: $OUT/（logcat.log + shots/ + health.txt）"
echo "后续: 把 screenshots 反馈给开发/agent 即可核对 §10 验收清单"