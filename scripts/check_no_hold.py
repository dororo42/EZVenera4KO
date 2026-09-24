#!/usr/bin/env python3
"""AC5.1/AC5.2 静态断言：插件关键路径不得依赖 hold（长按）。

Kindle 4 上 hold = ScreenKB+Press（2024.07+），不可发现且与用户既有认知
冲突；本项目红线（ADR-005）要求所有配置入口均为普通菜单项。
本脚本扫描非注释代码行中的 hold_* 用法。
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# ADR-005 是全项目红线：扫描 src/koreader-plugin 下所有插件
#（.koplugin 目录），而非仅 ezvenera.koplugin。
PLUGIN_DIR = ROOT / "src" / "koreader-plugin"

# 允许出现的白名单：仅帮助文案/文档注释提及（如 proxyconf 的 help_text）
FORBIDDEN = re.compile(r"\b(hold_input|hold_callback|hold_callback_func|"
                       r"hold_keep_menu_open)\b")


def scan_violations(text: str):
    """逐行剥离注释（含 --[[ ]] 块注释）后匹配 FORBIDDEN。"""
    violations = []
    in_block = False
    for lineno, line in enumerate(text.splitlines(), 1):
        code = ""
        rest = line
        if in_block:
            end = rest.find("]]")
            if end < 0:
                continue
            in_block = False
            rest = rest[end + 2:]
        while True:
            start = rest.find("--[[")
            if start >= 0:
                code += rest[:start]
                tail = rest[start + 4:]
                end = tail.find("]]")
                if end < 0:
                    in_block = True
                    break
                rest = tail[end + 2:]
                continue
            break
        if not in_block:
            idx = rest.find("--")
            code += rest[:idx] if idx >= 0 else rest
        if FORBIDDEN.search(code):
            violations.append(lineno)
    return violations


def main():
    lua_files = sorted(PLUGIN_DIR.glob("*.koplugin/**/*.lua"))
    if not lua_files:
        print("no .lua files found", file=sys.stderr)
        sys.exit(2)
    violations = []
    for f in lua_files:
        for lineno in scan_violations(
                f.read_text(encoding="utf-8")):
            violations.append(f"{f.relative_to(ROOT)}:{lineno}")

    if violations:
        print("HOLD-DEPENDENCY VIOLATIONS (ADR-005):")
        for v in violations:
            print("  " + v)
        sys.exit(1)
    print(f"hold-dependency check: clean "
          f"({len(lua_files)} files scanned)")
    sys.exit(0)


if __name__ == "__main__":
    main()