#!/usr/bin/env python3
"""Summarize source-derived helper infrastructure in output_bs.maude.

The goal is not to prove that every helper is non-isomorphic.  It gives a
stable inventory of names that are not direct SpecTec rule/def labels and
therefore need explanation in the C1 report.
"""

from __future__ import annotations

import argparse
import re
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


GROUPS: list[tuple[str, str, str]] = [
    (
        "step-from-step-pure-*",
        r"\bstep-from-step-pure-[A-Za-z0-9_-]+",
        "should be zero after the generic Step/ctxt-instrs cleanup",
    ),
    (
        "$infer-*",
        r"\$infer-[A-Za-z0-9_-]+",
        "witness inference for relation premises whose output variables are used later",
    ),
    (
        "$valid-*",
        r"\$valid-[A-Za-z0-9_-]+",
        "Boolean mirror for relation premises used inside eq/ceq definitions",
    ),
    (
        "$result-*",
        r"\$result-[A-Za-z0-9_-]+",
        "result extraction helper for relation premises with output witnesses",
    ),
    (
        "$cont-*",
        r"\$cont-[A-Za-z0-9_-]+",
        "continuation helper that keeps SpecTec def translations as eq/ceq",
    ),
    (
        "$map-*",
        r"\$map-[A-Za-z0-9_-]+",
        "star-map helper for SpecTec sequence mapping expressions",
    ),
    (
        "subtype decision mirrors",
        r"\$(?:heaptype|reftype)-sub\?",
        "Boolean decision mirror for executable otherwise branches",
    ),
    (
        "$empty-*",
        r"\$empty-[A-Za-z0-9_-]+",
        "canonical empty record constants",
    ),
    (
        "$is-spectec-*",
        r"\$is-spectec-[A-Za-z0-9_-]+",
        "category predicates; these should be small after typecheck cleanup",
    ),
    (
        "frame empty specializations",
        r"instrs-ok-frame-exec-tail-empty[A-Za-z0-9_-]*",
        "should be zero after removing non-progressing frame specializations",
    ),
]


def unique_matches(text: str, pattern: str) -> Counter[str]:
    return Counter(re.findall(pattern, text))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("maude_file", nargs="?", default="output_bs.maude")
    parser.add_argument("--top", type=int, default=20)
    args = parser.parse_args()

    path = Path(args.maude_file)
    if not path.is_absolute():
        path = ROOT / path
    text = path.read_text()

    print(f"# Non-isomorphic/source-derived helper inventory: {path}")
    print()
    for title, pattern, note in GROUPS:
        counts = unique_matches(text, pattern)
        total = sum(counts.values())
        print(f"## {title}")
        print(f"- total occurrences: {total}")
        print(f"- distinct names: {len(counts)}")
        print(f"- note: {note}")
        for name, count in counts.most_common(args.top):
            print(f"  - {name}: {count}")
        if len(counts) > args.top:
            print(f"  - ... {len(counts) - args.top} more")
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
