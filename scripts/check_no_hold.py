#!/usr/bin/env python3
"""AC5.1/AC5.2 静态断言：插件关键路径不得依赖 hold（长按）。

Kindle 4 上 hold = ScreenKB+Press（2024.07+），不可发现且与用户既有认知
冲突；本项目红线（ADR-005）要求所有配置入口均为普通菜单项。
本脚本扫描非注释、非字符串字面量代码中的 hold_* 用法。

M10（审查报告 §3，2026-09-25 重写扫描核心）：旧实现先按 `--` 截断再匹配，
字符串字面量里的 `--`（如 local s = "a--b"）会把行尾截断，隐藏真违规
（假阴性）。现改为单趟状态机：字符串（含 \\ 转义）与长注释在注释剥离
之前处理。自检: python scripts/check_no_hold.py --selftest
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# ADR-005 是全项目红线：扫描 src/koreader-plugin 下所有插件
#（.koplugin 目录），而非仅 ezvenera.koplugin。
PLUGIN_DIR = ROOT / "src" / "koreader-plugin"

FORBIDDEN = re.compile(r"\b(hold_input|hold_callback|hold_callback_func|"
                       r"hold_keep_menu_open)\b")


def code_part(line: str, in_block: bool):
    """单趟状态机：返回 (本行代码部分, 新的 in_block 状态)。

    顺序敏感：字符串字面量内的 -- 与 ]] 不是注释/结束符；
    字符串内容整体置空（保留列偏移便于定位）。
    """
    out = []
    i = 0
    n = len(line)
    while i < n:
        if in_block:
            end = line.find("]]", i)
            if end < 0:
                return "".join(out), True
            out.append(" " * (end + 2 - i))
            i = end + 2
            in_block = False
            continue
        ch = line[i]
        if ch == '"' or ch == "'":
            j = i + 1
            while j < n:
                if line[j] == "\\":
                    j += 2
                    continue
                if line[j] == ch:
                    break
                j += 1
            out.append(" " * (min(j, n) - i))
            i = min(j + 1, n)
            continue
        if ch == "-" and i + 1 < n and line[i + 1] == "-":
            if line[i + 2:i + 4] == "[[":
                end = line.find("]]", i + 4)
                if end < 0:
                    return "".join(out), True
                i = end + 2
                continue
            break  # 行注释：剩余全部丢弃
        out.append(ch)
        i += 1
    return "".join(out), in_block


def scan_violations(text: str):
    """返回违规行号列表（1-based）。"""
    violations = []
    in_block = False
    for lineno, line in enumerate(text.splitlines(), 1):
        code, in_block = code_part(line, in_block)
        if FORBIDDEN.search(code):
            violations.append(lineno)
    return violations


def selftest():
    """M10 活体探针：历史误报/漏报形态全部钉住。"""
    # 原缺陷：字符串内 -- 截断行尾，隐藏真违规
    viol = scan_violations('local s = "a--b"\nx.hold_input = true\n')
    assert viol == [2], f"string-comment probe: {viol}"
    # 注释里的 hold 不算违规
    viol = scan_violations("-- 使用 hold_input 是被禁止的\nlocal a = 1\n")
    assert viol == [], f"comment probe: {viol}"
    # 块注释跨行
    viol = scan_violations("--[[ 多行\nhold_callback\n]] x.hold_input = 1\n")
    assert viol == [3], f"block comment probe: {viol}"
    # 字符串内容里的 hold_input 属合法文档提及，不算违规
    viol = scan_violations('local help = "不用 hold_input"\n')
    assert viol == [], f"string content probe: {viol}"
    print("selftest OK")


def main():
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
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