#!/usr/bin/env python3
"""Collapse deterministic wasm2maude wrapper transitions into equations.

The generated official `rel.step` semantics is unchanged.  Only the four
wrapper transitions around it are reclassified from observable rewrite rules
to equations, so Maude normalizes deterministic instantiation/execution between
external scenario choices.  This is a stuttering reduction for properties that
observe only the terminal result of each SpaceWasm loader scenario.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def replace_once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"expected one occurrence, found {count}: {old!r}")
    return text.replace(old, new, 1)


def transform(text: str) -> str:
    text = replace_once(
        text,
        "  crl [instantiate] : boot => init(C)\n",
        "  ceq [instantiate-macro] : boot = init(C)\n",
    )
    text = replace_once(
        text,
        "  crl [init-step] : init(C) => init(C2)\n",
        "  ceq [init-step-macro] : init(C) = init(C2)\n",
    )
    text = replace_once(
        text,
        "  rl [invoke] :\n",
        "  eq [invoke-macro] :\n",
    )
    text = replace_once(
        text,
        "    => exec(def.invoke(\n",
        "    = exec(def.invoke(\n",
    )
    text = replace_once(
        text,
        "  crl [step] : exec(C) => exec(C2)\n",
        "  ceq [step-macro] : exec(C) = exec(C2)\n",
    )
    text, count = re.subn(
        r"\nrew \[[0-9]+\] in WASM2MAUDE-RUN : boot \.\s*$",
        "\nred in WASM2MAUDE-RUN : boot .\n",
        text,
        count=1,
    )
    if count != 1:
        raise RuntimeError("generated final rewrite command not found")
    return text


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_text(transform(args.input.read_text(encoding="utf-8")), encoding="utf-8")


if __name__ == "__main__":
    main()
