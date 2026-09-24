#!/bin/bash
# EZVenera for KOReader — 打包为 MRPI/KUAL 扩展 zip
# 用法：./scripts/package-mrpi.sh [版本号]
# 产物：dist/ezvenera-koreader-<version>.zip（解压后 ezvenera.koplugin 放入
#       <koreader>/plugins/ 并重启 KOReader）

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$ROOT/src/koreader-plugin/ezvenera.koplugin"
VERSION="${1:-M1}"
OUT="$ROOT/dist"
NAME="ezvenera-koreader-${VERSION}"

if [ ! -f "$PLUGIN/main.lua" ]; then
    echo "[err] plugin dir not found: $PLUGIN" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
rm -rf "$STAGE/$NAME"
mkdir -p "$STAGE/$NAME"
cp -r "$PLUGIN" "$STAGE/$NAME/"
# 打包前清理：引擎 .so 与设备 ABI 强相关，随包附带的仅作参考，默认剥离
rm -rf "$STAGE/$NAME/ezvenera.koplugin/lib" 2>/dev/null || true

cat > "$STAGE/$NAME/README-INSTALL.txt" <<'EOF'
EZVenera for KOReader — 安装（Kindle 4 / 非触屏）

前置：已越狱 + KUAL(booklet) + MRPI(legacy)。
1) 解压本包，将 ezvenera.koplugin 目录拷贝到
   <koreader>/plugins/ezvenera.koplugin
2) 重启 KOReader：工具 → EZVenera 漫画
3) 网络代理：默认为空（真机首配：菜单内『编辑代理地址』输入，全程无长按）
4) JS 引擎：如提示“引擎未安装”，见仓库 README 构建或下载
   lib/libquickjs.so（scripts/build-quickjs.sh，koxtoolchain kindle5 目标）
EOF

mkdir -p "$OUT"
ZIP="$OUT/$NAME.zip"
rm -f "$ZIP"
# zip 用 Python（Windows Git Bash 通常无 zip 命令）
python - "$STAGE/$NAME" "$ZIP" <<'PYEOF'
import sys, zipfile, os
from pathlib import Path
src, dst = Path(sys.argv[1]), Path(sys.argv[2])
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
    for p in sorted(src.rglob("*")):
        if p.is_file():
            z.write(p, p.relative_to(src.parent))
print("[ok]", dst)
PYEOF
du -h "$ZIP"
echo "[note] 解压后把 ezvenera.koplugin 放入 <koreader>/plugins/ 并重启 KOReader"