#!/usr/bin/env bash
# EZVenera for KOReader — 给注入引擎后的 APK 做对齐 + 重签名（可选 adb 安装）
#
# 用法：
#   KEYSTORE=$HOME/my.keystore KS_PASS=... [KEY_PASS=...] \
#     ./scripts/android/sign-apk.sh UNSIGNED.apk SIGNED.apk [--install]
#
# 前提：PATH 里有 zipalign 与 apksigner（Android SDK build-tools，或
#       Debian/Ubuntu 的 `apt install apksigner`）。
#
# 凭据红线：keystore 路径与口令一律走环境变量，写进脚本/仓库就等于泄露。
# 自己生成一份长期用的 keystore：
#   keytool -genkeypair -v -keystore ezv.keystore -alias ezv \
#           -keyalg RSA -keysize 2048 -validity 10000
#
# 注意：重签名后与 F-Droid/Google Play 的官方包签名不一致 —— 官方更新无法覆盖
#       安装，且首次装这份包要先卸载原 KOReader（阅读进度在 <sdcard>/koreader
#       下，卸载前建议备份）。

set -euo pipefail

UNSIGNED="${1:-}"; SIGNED="${2:-}"
INSTALL=0
[ "${3:-}" = "--install" ] && INSTALL=1
if [ -z "$UNSIGNED" ] || [ -z "$SIGNED" ]; then
    sed -n '2,18p' "$0" >&2; exit 2
fi
: "${KEYSTORE:?set KEYSTORE=/path/to/keystore}"
: "${KS_PASS:?set KS_PASS=<keystore password> (do not commit it)}"
KEY_PASS="${KEY_PASS:-$KS_PASS}"

command -v zipalign >/dev/null || { echo "[err] zipalign not in PATH" >&2; exit 1; }
command -v apksigner >/dev/null || { echo "[err] apksigner not in PATH" >&2; exit 1; }

ALIGNED="$(mktemp -t ezv-aligned-XXXXXX).apk"
trap 'rm -f "$ALIGNED"' EXIT

zipalign -f 4 "$UNSIGNED" "$ALIGNED"
apksigner sign --ks "$KEYSTORE" --ks-pass "pass:$KS_PASS" --key-pass "pass:$KEY_PASS" \
    --out "$SIGNED" "$ALIGNED"
apksigner verify --print-certs "$SIGNED" | head -6

if [ "$INSTALL" = 1 ]; then
    echo "[warn] 覆盖安装失败通常是签名不一致：先 adb uninstall org.koreader.launcher.fdroid"
    adb install -r "$SIGNED"
fi
echo "APK_SIGNED → $SIGNED"
