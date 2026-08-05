#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} LOG EXPECTED_I32")
    text = Path(sys.argv[1]).read_text(encoding="utf-8")
    expected = int(sys.argv[2])
    match = re.search(
        r"result RunState:.*instr\.const\(numtype\.i32,\s*"
        r"uN\.wrap\(([0-9]+)\)\)\)\s*Bye\.\s*$",
        text,
        re.DOTALL,
    )
    if match is None:
        raise SystemExit(f"could not find terminal i32 result in {sys.argv[1]}")
    actual = int(match.group(1))
    if actual != expected:
        raise SystemExit(
            f"unexpected terminal i32 result in {sys.argv[1]}: "
            f"expected {expected}, got {actual}"
        )


if __name__ == "__main__":
    main()
