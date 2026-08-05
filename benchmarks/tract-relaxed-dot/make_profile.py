#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path


def replace_once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"expected one occurrence, found {count}: {old!r}")
    return text.replace(old, new, 1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--r-idot", type=int, choices=(0, 1), required=True)
    args = parser.parse_args()

    text = args.input.read_text(encoding="utf-8")
    text = replace_once(
        text,
        "--- Backend semantics: official-spectec-deterministic.",
        f"--- Backend semantics: official-spectec-relaxed-r-idot-{args.r_idot}.",
    )
    text = replace_once(
        text,
        "eq builtin.nd = bool(false) .",
        "eq builtin.nd = bool(true) .",
    )
    text = replace_once(
        text,
        "eq builtin.r-idot = relaxed2.wrap(0) .",
        f"eq builtin.r-idot = relaxed2.wrap({args.r_idot}) .",
    )
    args.output.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
