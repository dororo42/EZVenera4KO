#!/bin/bash
# EZVenera for KOReader — 下载并 vendor quickjs-ng 源码到 rust/ezvjs-bridge/vendor/
# 用法：./scripts/fetch-quickjs.sh [--tag TAG]
#
# 来自 quickjs-ng/quickjs 的 CMake 源供 Rust cc crate 编译或独立构建。
# 需网络。输出目录 rust/ezvjs-bridge/vendor/quickjs/。
#
# 审查 L1（2026-09-20 修复）：
#   1. 原默认 tag "2025-05-20" 在 quickjs-ng 仓库不存在（curl 404）——
#      本脚本此前仅通过 bash -n 校验、从未真正运行成功。现 pin 到
#      实际存在的 release tag v0.17.0。
#   2. 下载后强制 sha256 校验。注意：codeload 归档由 GitHub 生成，
#      极小概率因基础设施变更重新生成导致哈希漂移——若校验失败且
#      你能确认 tarball 来源可信（对比官方 release 声明），可更新
#      EXPECTED_SHA256 并在此处留注变更原因。
#
# 更换 TAG 时必须同步更新 EXPECTED_SHA256（先下载人工核验来源）。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# M11（审查报告 §3）：--tag 解析——旧代码把 "--tag" 字面量当值。
# 注意：更换 TAG 必须同步更新下方 EXPECTED_SHA256。
TAG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --tag) TAG="$2"; shift 2 ;;
        *) TAG="$1"; shift ;;
    esac
done
TAG="${TAG:-v0.17.0}"

# sha256(https://github.com/quickjs-ng/quickjs/archive/refs/tags/v0.17.0.tar.gz)
# 实测于 2026-09-20（905393 bytes）
EXPECTED_SHA256="559bc4c420475e55c7ab4510adbc562f55d7524d75e8e89d79ce4bb02f5687d9"

SRC_URL="https://github.com/quickjs-ng/quickjs/archive/refs/tags/${TAG}.tar.gz"
DEST="$ROOT/rust/ezvjs-bridge/vendor/quickjs"

if [ -f "$DEST/quickjs.h" ]; then
    echo "[ok] quickjs already vendored at $DEST"
    exit 0
fi

echo "[fetch] downloading quickjs-ng @ $TAG ..."
TMP="$(mktemp -d)"
TARBALL="$TMP/quickjs.tar.gz"
curl -fsSL -o "$TARBALL" "$SRC_URL"

# 供应链校验（审查 L1）：哈希不符即中止，绝不解包
ACTUAL_SHA256="$(sha256sum "$TARBALL" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    echo "[err] sha256 mismatch for $SRC_URL" >&2
    echo "      expected: $EXPECTED_SHA256" >&2
    echo "      actual:   $ACTUAL_SHA256" >&2
    echo "      若为 GitHub 归档再生导致漂移：人工核验新 tarball 后更新本脚本" >&2
    echo "      的 EXPECTED_SHA256（并留注变更原因）；否则怀疑供应链污染，立即停用。" >&2
    rm -rf "$TMP"
    exit 1
fi

tar xzf "$TARBALL" -C "$TMP"

EXTRACTED="$(echo "$TMP"/quickjs-*)"
rm -rf "$DEST"
mv "$EXTRACTED" "$DEST"
rm -rf "$TMP"
echo "[ok] vendored to $DEST (sha256 verified: $TAG)"
