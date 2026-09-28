#!/usr/bin/env python3
"""AC5.1/AC5.2 静态断言：插件关键路径不得依赖 hold（长按）。

Kindle 4 上 hold = ScreenKB+Press（2024.07+），不可发现且与用户既有认知
冲突；本项目红线（ADR-005）要求所有配置入口均为普通菜单项。
本脚本扫描非注释、非字符串字面量代码中的 hold_* 用法。

M10（2026-09-25 重写）：单趟状态机，字符串先于注释剥离。
N3（2026-09-28）：支持多级长括号（--[==[ / [==[ ... ]==]）——
旧实现只认 [[ ]]，--[==[ 会被当行注释处理（理论假阳性）、
[=[ 长串内的 -- 会截断行尾（理论假阴性）。
自检: python scripts/check_no_hold.py --selftest
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

# Lua 长括号开启：[=*[（零个或多个 =）；闭合 ]=*]（等号数须一致）
LONG_OPEN = re.compile(r"\[=*\[")


def close_re(level: int):
    return re.compile("]" + "=" * level + "]")


def code_part(line: str, state):
    """单趟状态机：返回 (本行代码部分, 新状态)。

    state: None（代码中）或 ("block"|"long", level)——跨行的长注释/长串。
    处理顺序：长串/长注释内的 -- 与 ]] 不是结构符；字符串内容整体置空。
    """
    out = []
    i = 0
    n = len(line)
    while i < n:
        if state is not None:
            kind, level = state
            m = close_re(level).search(line, i)
            if not m:
                return "".join(out), state
            out.append(" " * (m.end() - i))
            i = m.end()
            state = None
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
        if ch == "[":
            # N3：长字符串字面量 [=*[（内容可含 --、hold_* 等）
            m3 = LONG_OPEN.match(line, i)
            if m3:
                level = m3.end() - i - 2
                m_end = close_re(level).search(line, m3.end())
                if not m_end:
                    return "".join(out), ("long", level)
                out.append(" " * (m_end.end() - i))
                i = m_end.end()
                continue
        if ch == "-" and i + 1 < n and line[i + 1] == "-":
            # N3：长注释（含多级 --[==[）
            m4 = LONG_OPEN.match(line, i + 2)
            if m4:
                level = (m4.end() - (i + 2)) - 2
                m_end = close_re(level).search(line, m4.end())
                if not m_end:
                    return "".join(out), ("block", level)
                i = m_end.end()
                continue
            break  # 行注释：剩余全部丢弃
        out.append(ch)
        i += 1
    return "".join(out), state


def scan_violations(text: str):
    """返回违规行号列表（1-based）。"""
    violations = []
    state = None
    for lineno, line in enumerate(text.splitlines(), 1):
        code, state = code_part(line, state)
        if FORBIDDEN.search(code):
            violations.append(lineno)
    return violations


def selftest():
    """活体探针：历史误报/漏报形态 + N3 多级长括号全部钉住。"""
    # 原缺陷：字符串内 -- 截断行尾，隐藏真违规
    viol = scan_violations('local s = "a--b"\nx.hold_input = true\n')
    assert viol == [2], f"string-comment probe: {viol}"
    # 注释里的 hold 不算违规
    viol = scan_violations("-- 使用 hold_input 是被禁止的\nlocal a = 1\n")
    assert viol == [], f"comment probe: {viol}"
    # 块注释跨行
    viol = scan_violations("--[[ 多行\nhold_callback\n]] x.hold_input = 1\n")
    assert viol == [3], f"block comment probe: {viol}"
    # 字符串内容里的 hold_input 属合法文档提及
    viol = scan_violations('local help = "不用 hold_input"\n')
    assert viol == [], f"string content probe: {viol}"
    # N3：--[==[ 多级长注释（旧实现会当行注释→正文误报）
    viol = scan_violations("--[==[ 多行\nhold_input\n]==]\nx.hold_input = 1\n")
    assert viol == [4], f"leveled block comment probe: {viol}"
    # N3：多级长字符串内的 -- 与 hold_* 不算违规（旧实现截断行尾）
    viol = scan_violations(
        "local s = [==[ text -- hold_input inside ]==]\nlocal ok = 1\n")
    assert viol == [], f"leveled long string probe: {viol}"
    # 普通长字符串跨行
    viol = scan_violations("local s = [[\nhold_callback\n]]\nlocal b = 1\n")
    assert viol == [], f"long string probe: {viol}"
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