#!/usr/bin/env python3
"""EZVenera for KOReader — 把引擎 .so 注进 KOReader APK。

用法：
    python3 scripts/android/patch-apk.py IN.apk OUT.apk LIBDIR [--abi arm64-v8a]

做两件事：
  1) 剥掉旧包的 v1 签名条目（META-INF/MANIFEST.MF 与 .SF/.RSA/.DSA/.EC），
     其余条目原样搬运（保留各自的压缩方式与属性），避免新旧签名混在一份包里；
  2) 追加 lib/<abi>/{libquickjs.so,libezvbridge.so}。

注：Android ≤6 的 linker 按「已加载库的 SONAME」解析 NEEDED，所以引擎在包内
叫 libquickjs.so、SONAME 是 libqjs.so.0 也没问题——宿主会先 dlopen 引擎。
"""
import argparse
import os
import sys
import zipfile

ENGINE_LIBS = ("libquickjs.so", "libezvbridge.so")
SIGNATURE_EXT = (".SF", ".RSA", ".DSA", ".EC")


def patch(src, dst, libdir, abi, libs):
    missing = [l for l in libs if not os.path.isfile(os.path.join(libdir, l))]
    if missing:
        sys.exit("[err] 引擎文件缺失：%s（先跑 scripts/android/build-engine-android.sh）"
                 % ", ".join(missing))

    copied = skipped = 0
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w") as zout:
        for item in zin.infolist():
            name = item.filename
            if name == "META-INF/MANIFEST.MF" or (
                    name.startswith("META-INF/") and name.endswith(SIGNATURE_EXT)):
                skipped += 1
                continue
            info = zipfile.ZipInfo(name, date_time=item.date_time)
            info.compress_type = item.compress_type
            info.external_attr = item.external_attr
            info.internal_attr = item.internal_attr
            info.create_system = item.create_system
            zout.writestr(info, zin.read(name))
            copied += 1
        for lib in libs:
            info = zipfile.ZipInfo("lib/%s/%s" % (abi, lib))
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(os.path.join(libdir, lib), "rb") as f:
                zout.writestr(info, f.read())
    print("[ok] copied=%d stripped-signature=%d added=%d -> %s"
          % (copied, skipped, len(libs), dst))


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("apk_in")
    ap.add_argument("apk_out")
    ap.add_argument("libdir")
    ap.add_argument("--abi", default="arm64-v8a")
    ap.add_argument("--libs", nargs="*", default=list(ENGINE_LIBS))
    a = ap.parse_args()
    patch(a.apk_in, a.apk_out, a.libdir, a.abi, a.libs)
