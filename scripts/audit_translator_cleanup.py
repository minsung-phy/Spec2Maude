#!/usr/bin/env python3
"""Audit cleanup invariants for the Spec2Maude translator artifact.

This script is intentionally conservative.  It does not prove that the whole
translator is source-isomorphic, but it catches stale internal names, forbidden
generated helper families, and documentation drift that have repeatedly caused
confusion during cleanup.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


FORBIDDEN_OUTPUT_PATTERNS = [
    (r"\bCTOR[A-Z0-9]*A[0-9]+\b", "old compact CTOR...A... constructor leaked"),
    (r"\$typed-index", "typed-index helper leaked into generated output"),
    (r"\$valid-", "validation mirror helper leaked into generated output"),
    (r"\$infer-", "inference helper leaked into generated output"),
    (r"\bJHS-T\b", "old JHS-T variable leaked into generated output"),
    (r"\bNTC\b", "old NTC variable leaked into generated output"),
    (r"\bITC\b", "old ITC variable leaked into generated output"),
]

FORBIDDEN_TRANSLATOR_PATTERNS = [
    (r"\bjhs[_A-Za-z0-9]*\b", "old jhs_* implementation name remains"),
    (r"\bJHS\b", "old JHS terminology remains"),
    (r"\bC1\b", "old C1 baseline terminology remains"),
    (r"source_ctor_name_of_legacy", "legacy constructor lookup remains"),
    (r"\bCTOR[A-Z0-9]*A[0-9]+\b", "hard-coded old compact constructor name remains"),
]

STALE_DOC_PATTERNS = [
    (r"warnings:\s*6", "stale warning count says 6"),
    (r"4 typed-index", "stale typed-index warning breakdown remains"),
    (r"typed-index sequence", "stale typed-index warning text remains"),
]

HELPER_FAMILIES = [
    r"\$raw-lit",
    r"\$wrap-lit",
    r"\$unmap-mapexpr",
    r"\$map-",
    r"\$zipmap-",
    r"\$free-",
    r"\$expanddt",
]

TRANSLATOR_COMPAT_PATTERNS = [
    (r"\$valid-", "validation mirror support code remains"),
    (r"\$infer-", "inference witness support code remains"),
]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def scan_patterns(path: Path, patterns: list[tuple[str, str]]) -> list[str]:
    if not path.exists():
        return [f"missing file: {path}"]
    text = read(path)
    failures: list[str] = []
    for pattern, message in patterns:
        match = re.search(pattern, text)
        if match:
            line = text[: match.start()].count("\n") + 1
            failures.append(f"{path}:{line}: {message}")
    return failures


def count_pattern(path: Path, pattern: str) -> int:
    if not path.exists():
        return 0
    return len(re.findall(pattern, read(path)))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--translator", default="translator.ml")
    parser.add_argument("--output", default="output.maude")
    parser.add_argument(
        "--docs",
        nargs="*",
        default=["README.md", "STATUS.md", "ARTIFACT.md", "docs/HowToTest.md", "docs/limitation.md"],
    )
    args = parser.parse_args()

    translator = Path(args.translator)
    output = Path(args.output)
    docs = [Path(p) for p in args.docs]

    failures: list[str] = []
    warnings: list[str] = []

    failures.extend(scan_patterns(translator, FORBIDDEN_TRANSLATOR_PATTERNS))
    failures.extend(scan_patterns(output, FORBIDDEN_OUTPUT_PATTERNS))
    for doc in docs:
        failures.extend(scan_patterns(doc, STALE_DOC_PATTERNS))

    if output.exists():
        for family in HELPER_FAMILIES:
            count = count_pattern(output, family)
            if count:
                warnings.append(f"{output}: remaining helper family {family}: {count}")

    if translator.exists():
        for pattern, message in TRANSLATOR_COMPAT_PATTERNS:
            count = count_pattern(translator, pattern)
            if count:
                warnings.append(f"{translator}: {message}: {count}")

    print("Translator cleanup audit")
    if failures:
        print("FAIL")
        for failure in failures:
            print(f"  - {failure}")
    else:
        print("PASS: no forbidden cleanup regressions found")

    if warnings:
        print("Remaining helper families to document or redesign:")
        for warning in warnings:
            print(f"  - {warning}")

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
