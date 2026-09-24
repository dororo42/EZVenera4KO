#!/usr/bin/env python3
"""语法检查：用 LuaJIT（与 KOReader 同运行时）编译插件全部 .lua 文件。

覆盖单测未触及的模块（main.lua / jshost.lua 等）的语法错误。
"""

import sys
from pathlib import Path

import lupa.luajit21 as luajit_mod

ROOT = Path(__file__).resolve().parent.parent
PLUGIN_DIR = ROOT / "src" / "koreader-plugin"


def main():
    rt = luajit_mod.LuaRuntime()
    files = sorted(PLUGIN_DIR.glob("*.koplugin/**/*.lua"))
    if not files:
        print("no .lua files found", file=sys.stderr)
        sys.exit(2)
    failed = 0
    for f in files:
        code = f.read_text(encoding="utf-8")
        try:
            rt.compile(code)
            print(f"  OK  {f.relative_to(ROOT)}")
        except Exception as e:
            print(f"  FAIL {f.relative_to(ROOT)}: {e}")
            failed += 1
    print(f"\nSyntax check: {len(files) - failed}/{len(files)} OK")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()