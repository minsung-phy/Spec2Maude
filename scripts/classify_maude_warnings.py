#!/usr/bin/env python3
"""Classify Maude load warnings from a saved log.

This is intentionally lightweight: it does not decide semantic correctness, but
it gives the C1 audit a stable list of used-before-bound warnings to triage.
"""

from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path


VALIDATION_PREFIXES = (
    "numtype-",
    "vectype-",
    "heaptype-",
    "reftype-",
    "valtype-",
    "resulttype-",
    "instrtype-",
    "subtype-",
    "deftype-",
    "comptype-",
    "fieldtype-",
    "globaltype-",
    "tagtype-",
    "externtype-",
    "instr-ok-",
    "instrs-ok-",
    "expr-ok-",
    "global-ok-",
    "func-ok-",
    "module-ok-",
    "externaddr-ok-",
    "ref-ok-",
)


def warning_blocks(lines: list[str]) -> list[str]:
    blocks: list[str] = []
    i = 0
    starts = ("Warning: ", "Advisory: ")
    command_starts = ("reduce ", "rewrite ", "search ", "Bye.")
    while i < len(lines):
        line = lines[i]
        if line.startswith(starts):
            block = [line]
            i += 1
            while i < len(lines) and not lines[i].startswith(starts + command_starts):
                block.append(lines[i])
                i += 1
            blocks.append("\n".join(block))
        else:
            i += 1
    return blocks


def label_of(block: str) -> str:
    m = re.search(r"(?:crl|rl) \[([^\]]+)\]", block)
    return m.group(1) if m else ""


def line_of(block: str) -> str:
    m = re.search(r"line (\d+)", block)
    return m.group(1) if m else ""


def variable_of(block: str) -> str:
    m = re.search(r"variable\s+([A-Z0-9\-]+)", block)
    return m.group(1) if m else ""


def classify(block: str) -> str:
    if "used before it is bound" in block:
        label = label_of(block)
        if label.startswith(VALIDATION_PREFIXES):
            return "used-before-bound/validation"
        if label:
            return "used-before-bound/execution-or-def"
        return "used-before-bound/unknown-label"
    if "multiple distinct" in block and "parse" in block:
        return "multiple-distinct-parses"
    if (
        "all the variables in" in block
        and "assignment condition fragment" in block
        and "bound before the matching" in block
    ):
        return "assignment-fragment-advisory"
    if "membership axioms are not guaranteed" in block:
        return "membership-axiom-advisory"
    if "collapse at top" in block:
        return "collapse-advisory"
    if "has\n    been imported from both" in block or "has been imported from both" in block:
        return "duplicate-import-advisory"
    return "other"


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} MAUDE_LOG", file=sys.stderr)
        return 2

    log_path = Path(sys.argv[1])
    lines = log_path.read_text(errors="replace").splitlines()
    blocks = warning_blocks(lines)
    counts = Counter(classify(block) for block in blocks)

    print("warning_category,count")
    for key in sorted(counts):
        print(f"{key},{counts[key]}")

    print()
    print("line,label,variable,category")
    for block in blocks:
        category = classify(block)
        if category.startswith("used-before-bound"):
            print(f"{line_of(block)},{label_of(block)},{variable_of(block)},{category}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
