#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path


def replace_all(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count == 0:
        raise RuntimeError(f"expected at least one occurrence: {old!r}")
    return text.replace(old, new)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--r-idot", type=int, choices=(0, 1), required=True)
    args = parser.parse_args()

    text = args.input.read_text(encoding="utf-8")
    # builtins.maude intentionally repeats the backend-profile banner and may
    # expose the profile equations through more than one generated module.
    # Keep every occurrence globally consistent for a single legal execution
    # profile, as required by the official relaxed-SIMD semantics.
    text = replace_all(
        text,
        "--- Backend semantics: official-spectec-deterministic.",
        f"--- Backend semantics: official-spectec-relaxed-r-idot-{args.r_idot}.",
    )
    text = replace_all(
        text,
        "eq builtin.nd = bool(false) .",
        "eq builtin.nd = bool(true) .",
    )
    text = replace_all(
        text,
        "eq builtin.r-idot = relaxed2.wrap(0) .",
        f"eq builtin.r-idot = relaxed2.wrap({args.r_idot}) .",
    )
    args.output.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
