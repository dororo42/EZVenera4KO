#!/usr/bin/env python3
"""EZVenera for KOReader — Lua 单测运行器（KOReader 同运行时：LuaJIT 2.1 / Lua 5.1）

用法:
  tools/.venv/Scripts/python.exe scripts/run_tests.py [子串...]
"""

import sys
from pathlib import Path

import lupa.luajit21 as luajit_mod

ROOT = Path(__file__).resolve().parent.parent
PLUGIN_DIR = ROOT / "src" / "koreader-plugin"
TESTS = ROOT / "tests"


def koplugin_paths():
    """注册 src/koreader-plugin 下所有 .koplugin（多插件共存）。"""
    paths = []
    if PLUGIN_DIR.is_dir():
        for d in sorted(PLUGIN_DIR.iterdir()):
            if d.is_dir() and d.name.endswith(".koplugin"):
                paths.append(d.as_posix() + "/?.lua")
                paths.append(d.as_posix() + "/?/init.lua")
    return paths


def main():
    args = sys.argv[1:]
    rt = luajit_mod.LuaRuntime(unpack_returned_tuples=True)

    paths = koplugin_paths() + [TESTS.as_posix() + "/?.lua",
                                ROOT.as_posix() + "/?.lua",
                                rt.eval("package.path")]
    newpath = ";".join(paths)
    rt.globals()["_P_TESTPATH"] = newpath
    rt.execute("package.path = _P_TESTPATH .. ';' .. package.path")
    rt.execute("math.randomseed(os.time() % 1000)")

    test_files = sorted(TESTS.glob("test_*.lua"))
    if args:
        test_files = [f for f in test_files
                      if any(a in f.name for a in args)]
    if not test_files:
        print("No test files found matching", args)
        sys.exit(1)

    total_pass = 0
    total_fail = 0
    load_error = False

    for fp in test_files:
        code = fp.read_text(encoding="utf-8")
        try:
            chunk = rt.compile(code)
            tests_table = chunk()
        except Exception as e:
            print(f"LOAD ERROR {fp.name}: {e}")
            load_error = True
            continue

        if tests_table is None:
            print(f"SKIP {fp.name} (chunk returned nil)")
            continue

        print(f"[{fp.name}]")
        names = sorted(tests_table.keys())
        for name in names:
            fn = tests_table[name]
            if not callable(fn):
                continue
            try:
                ok = fn()
                if ok is True:
                    print(f"  PASS ::{name}")
                    total_pass += 1
                else:
                    print(f"  FAIL ::{name} — returned {ok!r}")
                    total_fail += 1
            except Exception as e:
                print(f"  FAIL ::{name} — {e}")
                total_fail += 1

    print()
    print(f"Results: {total_pass} passed, {total_fail} failed"
          + (", load errors" if load_error else ""))
    sys.exit(1 if (total_fail or load_error) else 0)


if __name__ == "__main__":
    main()