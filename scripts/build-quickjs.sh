#!/bin/bash
# EZVenera for KOReader — 交叉编译 quickjs-ng 为 libquickjs.so
# 用法：./scripts/build-quickjs.sh [--target kindle|x86_64|host]
#
# --target kindle  : arm-kindle5-linux-gnueabi (softfp, glibc 2.12) via koxtoolchain
# --target x86_64  : Linux x86_64 开发/CI 用（需要 gcc/cmake 在 PATH）
# --target host    : 本机直接编译（默认）
#
# 前提：
#   - kindle: koxtoolchain 已装（~/x-tools/arm-kindle5-linux-gnueabi/bin/），
#             源码已在 rust/ezvjs-bridge/vendor/quickjs/（执行 fetch-quickjs.sh）
#   - x86_64: gcc/cmake 可用
#   - 输出: src/koreader-plugin/ezvenera.koplugin/lib/libquickjs.so

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/rust/ezvjs-bridge/vendor/quickjs"
OUTDIR="$ROOT/src/koreader-plugin/ezvenera.koplugin/lib"
TARGET="${1:-host}"

if [ "$TARGET" = "host" ] || [ "$TARGET" = "x86_64" ]; then
    echo "[build] host/x86_64 target"
    if [ ! -f "$VENDOR/quickjs.h" ]; then
        echo "[err] vendor/quickjs not found. Run scripts/fetch-quickjs.sh first." >&2
        exit 1
    fi
    mkdir -p "$OUTDIR"
    BUILD="$ROOT/build/quickjs-host"
    mkdir -p "$BUILD"
    # 审查 M11：显式 BUILD_SHARED_LIBS=ON——quickjs-ng CMake 默认 OFF，
    # 只产出 .a；把 .a 改名 .so 会让 ffi.load 报 invalid ELF header
    ( cd "$BUILD" && cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON "$VENDOR" && make -j"$(nproc)" )
    # H2（审查报告 §2）：产物名兼容——quickjs-ng CMake 实际产出
    # libqjs.so.<ver>（与 kindle 分支同一套 glob），别再只认 libquickjs.so
    LIBFILE=""
    for f in "$BUILD/libquickjs.so" "$BUILD"/libquickjs.so.* "$BUILD"/libqjs.so.*.*; do
        if [ -e "$f" ] || [ -L "$f" ]; then LIBFILE="$f"; break; fi
    done
    if [ -z "$LIBFILE" ]; then
        echo "[err] quickjs shared library not built (check cmake output above)" >&2
        exit 1
    fi
    cp -L "$LIBFILE" "$OUTDIR/libquickjs.so"
    strip "$OUTDIR/libquickjs.so" 2>/dev/null || true
    echo "[ok] $OUTDIR/libquickjs.so ($(wc -c < "$OUTDIR/libquickjs.so") bytes)"
elif [ "$TARGET" = "kindle" ]; then
    echo "[build] kindle target (arm-kindle5-linux-gnueabi)"
    if [ ! -f "$VENDOR/quickjs.h" ]; then
        echo "[err] vendor/quickjs not found. Run scripts/fetch-quickjs.sh first." >&2
        exit 1
    fi
    if [ ! -f "$HOME/x-tools/arm-kindle5-linux-gnueabi/bin/arm-kindle5-linux-gnueabi-gcc" ]; then
        echo "[err] koxtoolchain kindle5 not found at ~/x-tools/arm-kindle5-linux-gnueabi/." >&2
        echo "      Install: git clone https://github.com/koreader/koxtoolchain && cd koxtoolchain && ./gen-tc.sh kindle5" >&2
        exit 1
    fi
    mkdir -p "$OUTDIR"
    BUILD="$ROOT/build/quickjs-kindle"
    mkdir -p "$BUILD"
    TOOLCHAIN="$HOME/x-tools/arm-kindle5-linux-gnueabi"
    export CC="$TOOLCHAIN/bin/arm-kindle5-linux-gnueabi-gcc"
    export CXX="$TOOLCHAIN/bin/arm-kindle5-linux-gnueabi-g++"
    export AR="$TOOLCHAIN/bin/arm-kindle5-linux-gnueabi-ar"
    export STRIP="$TOOLCHAIN/bin/arm-kindle5-linux-gnueabi-strip"
    export CFLAGS="-march=armv7-a -mtune=cortex-a8 -mfpu=neon -mfloat-abi=softfp -mthumb -Os"
    ( cd "$BUILD" && cmake -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_AR="$AR" -DCMAKE_STRIP="$STRIP" \
        -DCMAKE_C_FLAGS="$CFLAGS" "$VENDOR" && make -j"$(nproc)" )
    # quickjs-ng CMake 产物实际名为 libqjs.so.<ver>（target 名为 qjs），并非 libquickjs.so；
    # 兼容两种命名，取真实文件（解引用符号链接）复制为 KOReader 加载名 libquickjs.so
    LIBFILE=""
    for f in "$BUILD/libquickjs.so" "$BUILD"/libquickjs.so.* "$BUILD"/libqjs.so.*.*; do
        if [ -e "$f" ] || [ -L "$f" ]; then LIBFILE="$f"; break; fi
    done
    if [ -z "$LIBFILE" ]; then
        echo "[err] quickjs shared library not built (check cmake output above)" >&2
        exit 1
    fi
    cp -L "$LIBFILE" "$OUTDIR/libquickjs.so"
    "$STRIP" "$OUTDIR/libquickjs.so"
    echo "[ok] $OUTDIR/libquickjs.so ($(wc -c < "$OUTDIR/libquickjs.so") bytes)"
    echo "[note] verify: file $OUTDIR/libquickjs.so should show ARM EABI5 soft-float"
else
    echo "Usage: $0 [--target kindle|x86_64|host]" >&2
    exit 1
fi