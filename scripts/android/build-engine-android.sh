#!/usr/bin/env bash
# EZVenera for KOReader — Android arm64 JS 引擎构建（零 patchelf 配方，真机验证过）
#
# 用法：
#   NDK=/path/to/android-ndk ./scripts/android/build-engine-android.sh [--install] [--abi arm64-v8a]
#   产物：build/android-engine/{libquickjs.so,libezvbridge.so}
#        --install 再拷进 src/koreader-plugin/ezvenera.koplugin/lib/
#
# 前提（Linux/WSL）：
#   - Android NDK（r27c 实测；含 aarch64-linux-android21-clang 与 llvm-* 工具）
#   - cmake + make
#   - 先跑 scripts/fetch-quickjs.sh，把 quickjs-ng 源码放到
#     rust/ezvjs-bridge/vendor/quickjs/
#
# 为什么坚持「零 patchelf」：
#   patchelf --set-soname 会破坏 DT_STRTAB 与 section 视图的对应，Android ≤6 的
#   linker 读 verneed 时拿到乱串符号名而拒载本库（真机表现为 dlopen 直接失败）。
#   引擎文件名与它的 SONAME 不必一致：宿主 jshost.lua 先按绝对路径 dlopen
#   libquickjs.so（其 SONAME 随即进入 linker 命名空间），之后 shim 的
#   NEEDED=libqjs.so.0 就能命中已加载库。因此这里只做 cp + strip，绝不改 ELF。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VENDOR="$ROOT/rust/ezvjs-bridge/vendor/quickjs"
SHIM_SRC="$ROOT/shim/ezvbridge.c"
BUILD="$ROOT/build/quickjs-android"
OUT="$ROOT/build/android-engine"
LIBDIR="$ROOT/src/koreader-plugin/ezvenera.koplugin/lib"
ABI="arm64-v8a"
API=21
INSTALL=0

NDK="${NDK:-${ANDROID_NDK_HOME:-$HOME/android-ndk}}"

while [ $# -gt 0 ]; do
    case "$1" in
        --install) INSTALL=1; shift ;;
        --abi) ABI="$2"; shift 2 ;;
        --abi=*) ABI="${1#--abi=}"; shift ;;
        --ndk) NDK="$2"; shift 2 ;;
        --ndk=*) NDK="${1#--ndk=}"; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "[err] unknown arg: $1" >&2; exit 2 ;;
    esac
done

case "$ABI" in
    arm64-v8a) TARGET_TRIPLE="aarch64-linux-android" ;;
    armeabi-v7a) TARGET_TRIPLE="armv7a-linux-androideabi" ;;
    x86_64) TARGET_TRIPLE="x86_64-linux-android" ;;
    *) echo "[err] unsupported abi: $ABI" >&2; exit 2 ;;
esac

TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
CC="$TC/${TARGET_TRIPLE}${API}-clang"

[ -d "$NDK" ] || { echo "[err] NDK not found: $NDK  (set NDK= or --ndk=)" >&2; exit 1; }
[ -x "$CC" ] || { echo "[err] compiler not found: $CC" >&2; exit 1; }
[ -f "$VENDOR/quickjs.h" ] || { echo "[err] quickjs source missing — run scripts/fetch-quickjs.sh first" >&2; exit 1; }
[ -f "$SHIM_SRC" ] || { echo "[err] shim source missing: $SHIM_SRC" >&2; exit 1; }

READELF="$TC/llvm-readelf"
NM="$TC/llvm-nm"
STRIP="$TC/llvm-strip"

rm -rf "$OUT" "$BUILD"
mkdir -p "$OUT" "$BUILD"

echo "=== [1/4] cmake（直接覆盖 CC/CXX，不用 NDK toolchain file）==="
( cd "$BUILD" && cmake \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="${TC}/${TARGET_TRIPLE}${API}-clang++" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM="android-$API" \
    -DCMAKE_ANDROID_NDK="$NDK" \
    -DCMAKE_MAKE_PROGRAM="$(command -v make)" \
    "$VENDOR" > cmake.log 2>&1 ) || { echo "[err] cmake failed"; tail -20 "$BUILD/cmake.log"; exit 1; }

echo "=== [2/4] make（quickjs 自带的测试可执行文件编不过可以忽略）==="
( cd "$BUILD" && make -j"$(nproc 2>/dev/null || echo 4)" > make.log 2>&1 ) || echo "[warn] make returned non-zero — 只要 libqjs.so 在就继续"
LIBQJS="$(ls "$BUILD"/libqjs.so* "$BUILD"/libqjs.so 2>/dev/null | head -1 || true)"
[ -n "$LIBQJS" ] || { echo "[err] no libqjs.so produced"; tail -20 "$BUILD/make.log"; exit 1; }

echo "=== [3/4] 引擎 cp + strip，shim 自然链接（全程零 patchelf）==="
cp -L "$LIBQJS" "$OUT/libquickjs.so"
"$STRIP" --strip-unneeded "$OUT/libquickjs.so"

( cd "$BUILD" && "$CC" -shared -fPIC -O2 -I "$VENDOR" \
    "$SHIM_SRC" -o "$OUT/libezvbridge.so" \
    -L. -l:libqjs.so \
    -Wl,-soname,libezvbridge.so )
"$STRIP" --strip-unneeded "$OUT/libezvbridge.so"

echo "=== [4/4] ELF 验证 ==="
for f in libquickjs.so libezvbridge.so; do
    echo "--- $f ---"
    "$READELF" -h "$OUT/$f" | grep -E 'Class:|Machine:'
    "$READELF" -d "$OUT/$f" | grep -E 'SONAME|NEEDED|TEXTREL|RPATH|RUNPATH' || true
done
if "$READELF" -d "$OUT/libquickjs.so" | grep -q TEXTREL; then
    echo "[err] libquickjs.so has TEXTREL — 不能上安卓" >&2; exit 1
fi
"$NM" -D --defined-only "$OUT/libezvbridge.so" | grep -q ezv_install_bridge \
    || { echo "[err] shim 缺 ezv_install_bridge 导出" >&2; exit 1; }
for s in JS_NewRuntime JS_NewContext JS_Eval JS_ToCStringLen2 JS_NewStringLen JS_NewCFunction2; do
    "$NM" -D --defined-only "$OUT/libquickjs.so" | grep -q " $s\$" \
        || { echo "[err] engine 缺符号 $s" >&2; exit 1; }
done

if [ "$INSTALL" = 1 ]; then
    mkdir -p "$LIBDIR"
    cp -f "$OUT/libquickjs.so" "$OUT/libezvbridge.so" "$LIBDIR/"
    echo "[ok] 已安装到 $LIBDIR"
fi

sha256sum "$OUT"/*.so
echo "ENGINE_OK → $OUT"
