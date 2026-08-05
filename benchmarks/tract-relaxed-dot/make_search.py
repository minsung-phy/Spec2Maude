#!/usr/bin/env python3
"""Replace wasm2maude's concrete rewrite with a bad-result reachability query."""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--bad-result", type=int, default=1)
    args = parser.parse_args()

    text = args.input.read_text(encoding="utf-8")
    marker = "\nrew ["
    if marker not in text:
        raise RuntimeError("generated rewrite command was not found")
    text = text.split(marker, 1)[0].rstrip() + "\n\n"
    text += (
        "search [1] in WASM2MAUDE-RUN :\n"
        "  boot =>* exec(config.sym(S:SpectecTerminal, "
        f"instr.const(numtype.i32, uN.wrap({args.bad_result})))) .\n"
        "quit\n"
    )
    args.output.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
