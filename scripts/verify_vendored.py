#!/usr/bin/env python3
"""校验 vendored/init.js 完整性：sha256 与同目录 .sha256 记录一致。

防止 vendor 文件被意外改动而未同步上游（ADR-002 溯源）。
"""

import hashlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "src" / "koreader-plugin" / "ezvenera.koplugin" / "vendored"


def main():
    data = (VENDOR / "init.js").read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    recorded = (VENDOR / "init.js.sha256").read_text(
        encoding="utf-8").split()[0].strip().lower()
    if actual != recorded:
        print(f"VENDORED init.js HASH MISMATCH\n"
              f"  recorded: {recorded}\n  actual:   {actual}\n"
              f"If intentional, re-run: py -c \"import hashlib; open(...,'w')"
              f".write(hashlib.sha256(open('init.js','rb').read())"
              f".hexdigest())\" and update the provenance header.")
        sys.exit(1)
    print(f"vendored init.js verified: {actual[:16]}…")
    sys.exit(0)


if __name__ == "__main__":
    main()