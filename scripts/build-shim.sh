#!/bin/bash
# EZVenera for KOReader — 编译桥接 C shim（S2/T19）
# 用法：./scripts/build-shim.sh [--target host|x86_64|kindle] [--test]
#
# 产物：src/koreader-plugin/ezvenera.koplugin/lib/libezvbridge.so
#   host/x86_64  : 本机/Linux CI 用（--test 时连带编译运行 shim/test_shim.c）
#   kindle       : arm-kindle5-linux-gnueabi (softfp)，与 build-quickjs.sh kindle
#                  同一工具链与 CFLAGS；产物 DT_NEEDED 统一改写为 libquickjs.so
#                  （quickjs-ng CMake 产物 SONAME 实为 libqjs.so.0，需 patchelf）
#
# 前提：
#   - 源码：rust/ezvjs-bridge/vendor/quickjs/（scripts/fetch-quickjs.sh）
#   - 先跑 build-quickjs.sh <target> 产出 libquickjs.so（本脚本只链接不重编引擎）
#   - kindle: koxtoolchain 已装（~/x-tools/arm-kindle5-linux-gnueabi/）+
#             patchelf（apt install patchelf）

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/rust/ezvjs-bridge/vendor/quickjs"
SHIM="$ROOT/shim"
OUTDIR="$ROOT/src/koreader-plugin/ezvenera.koplugin/lib"
TARGET="host"
RUN_TEST=0

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --target=*) TARGET="${1#--target=}"; shift ;;
        host|x86_64|kindle) TARGET="$1"; shift ;;
        --test) RUN_TEST=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ ! -f "$VENDOR/quickjs.h" ]; then
    echo "[err] quickjs headers not found at $VENDOR — run scripts/fetch-quickjs.sh first." >&2
    exit 1
fi

find_engine_lib() {  # $1 = build dir；输出最真实的 .so（解引用前按精度排序）
    local d="$1" f
    for f in "$d"/libqjs.so.*.* "$d"/libquickjs.so "$d"/libquickjs.so.*; do
        if [ -e "$f" ] || [ -L "$f" ]; then
            printf '%s' "$f"
            return 0
        fi
    done
    return 1
}

if [ "$TARGET" = "host" ] || [ "$TARGET" = "x86_64" ]; then
    BUILD="$ROOT/build/quickjs-host"
    QJSLIB="$(find_engine_lib "$BUILD")" || {
        echo "[err] host libquickjs.so not found in $BUILD — run: ./scripts/build-quickjs.sh host" >&2
        exit 1
    }
    mkdir -p "$OUTDIR"
    echo "[build-shim] host target, engine lib: $QJSLIB"
    gcc -shared -fPIC -O2 -I"$VENDOR" \
        "$SHIM/ezvbridge.c" -o "$OUTDIR/libezvbridge.so" \
        -L"$BUILD" -l:libquickjs.so \
        -Wl,-soname,libezvbridge.so -Wl,-rpath,'$ORIGIN'
    if [ "$RUN_TEST" = "1" ]; then
        BIN="$BUILD/test_shim"
        gcc -O2 -I"$VENDOR" "$SHIM/test_shim.c" "$SHIM/ezvbridge.c" \
            -o "$BIN" -L"$BUILD" -l:libquickjs.so \
            -Wl,-rpath,"$BUILD"
        ( cd "$BUILD" && LD_LIBRARY_PATH="$BUILD" ./test_shim )
    fi
    echo "[ok] $OUTDIR/libezvbridge.so ($(wc -c < "$OUTDIR/libezvbridge.so") bytes)"
elif [ "$TARGET" = "kindle" ]; then
    TC="$HOME/x-tools/arm-kindle5-linux-gnueabi"
    GCC="$TC/bin/arm-kindle5-linux-gnueabi-gcc"
    STRIP="$TC/bin/arm-kindle5-linux-gnueabi-strip"
    READELF="$TC/bin/arm-kindle5-linux-gnueabi-readelf"
    if [ ! -x "$GCC" ]; then
        echo "[err] koxtoolchain kindle5 not found at $TC" >&2
        exit 1
    fi
    BUILD="$ROOT/build/quickjs-kindle"
    QJSLIB="$(find_engine_lib "$BUILD")" || {
        echo "[err] kindle libquickjs.so not found in $BUILD — run: ./scripts/build-quickjs.sh kindle" >&2
        exit 1
    }
    mkdir -p "$OUTDIR"
    echo "[build-shim] kindle target (arm-kindle5 softfp), engine lib: $QJSLIB"
    CFLAGS="-march=armv7-a -mtune=cortex-a8 -mfpu=neon -mfloat-abi=softfp -mthumb -Os"
    "$GCC" -shared -fPIC $CFLAGS -I"$VENDOR" \
        "$SHIM/ezvbridge.c" -o "$OUTDIR/libezvbridge.so" \
        -L"$BUILD" -l:libquickjs.so \
        -Wl,-soname,libezvbridge.so -Wl,-rpath,'$ORIGIN'
    # quickjs-ng CMake 产物 SONAME 为 libqjs.so.0（若 ld 记录了它），
    # 设备上文件名是 libquickjs.so —— 用 patchelf 把 DT_NEEDED 改写一致。
    if command -v patchelf >/dev/null 2>&1; then
        NEEDLIST="$($READELF -d "$OUTDIR/libezvbridge.so" | grep NEEDED | grep -o '\[.*\]' | tr -d '[]' || true)"
        for n in $NEEDLIST; do
            if [ "$n" != "libquickjs.so" ]; then
                case "$n" in
                    lib*) patchelf --replace-needed "$n" libquickjs.so "$OUTDIR/libezvbridge.so"
                          echo "[patchelf] NEEDED $n -> libquickjs.so" ;;
                esac
            fi
        done
    else
        echo "[warn] patchelf not found — 若 readelf 显示 NEEDED libqjs.so.0 请安装后重跑" >&2
    fi
    "$STRIP" "$OUTDIR/libezvbridge.so" 2>/dev/null || true
    echo "[verify] $($READELF -h "$OUTDIR/libezvbridge.so" | grep -E 'Machine|Flags' | tr '\n' ' ')"
    $READELF -d "$OUTDIR/libezvbridge.so" | grep -E 'NEEDED|SONAME|RPATH|RUNPATH' || true
    echo "[ok] $OUTDIR/libezvbridge.so ($(wc -c < "$OUTDIR/libezvbridge.so") bytes)"
else
    echo "Usage: $0 [--target host|x86_64|kindle] [--test]" >&2
    exit 2
fi
