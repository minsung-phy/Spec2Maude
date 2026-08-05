#!/usr/bin/env python3
"""Parameterize a wasm2maude run over a finite packed-i8 byte interval."""

from __future__ import annotations

import argparse
import re
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
    parser.add_argument("--module-name", required=True)
    parser.add_argument("--start", type=int, default=0)
    parser.add_argument("--max", type=int, default=255)
    args = parser.parse_args()
    if not (0 <= args.start <= args.max <= 255):
        raise SystemExit("require 0 <= start <= max <= 255")

    text = args.input.read_text(encoding="utf-8")
    marker = "\nrew ["
    if marker not in text:
        raise RuntimeError("generated run command marker was not found")
    text = text.split(marker, 1)[0].rstrip() + "\n"

    first_newline = text.find("\n")
    if first_newline < 0:
        raise RuntimeError("generated file has no initial load line")
    text = (
        text[: first_newline + 1]
        + "load model-checker.maude\n\n"
        + text[first_newline + 1 :]
    )

    text = replace_once(text, "mod WASM2MAUDE-RUN is", f"mod {args.module_name} is")
    text = replace_once(
        text,
        "  protecting WASM-BUILTINS .",
        "  protecting WASM-BUILTINS .\n  including MODEL-CHECKER .",
    )
    text = replace_once(
        text,
        "  sort RunState .",
        "  sort RunState .\n  subsort RunState < State .",
    )
    text = replace_once(
        text,
        "  op boot : -> RunState [ctor] .",
        "  op choose : Nat -> RunState [ctor] .\n"
        "  op boot : Nat -> RunState [ctor] .",
    )
    text = replace_once(
        text,
        "  op init : SpectecTerminal -> RunState [ctor frozen (1)] .",
        "  op init : Nat SpectecTerminal -> RunState [ctor frozen (2)] .",
    )
    text = replace_once(
        text,
        "  op exec : SpectecTerminal -> RunState [ctor frozen (1)] .",
        "  op exec : Nat SpectecTerminal -> RunState [ctor frozen (2)] .",
    )
    text = replace_once(
        text,
        "  op inputArgs : -> SpectecTerminals .",
        "  op inputArgs : Nat -> SpectecTerminals .",
    )
    text = replace_once(
        text,
        "  vars C C2 S MI NAME OTHER ADDR XA : SpectecTerminal .",
        "  vars C C2 S MI NAME OTHER ADDR XA : SpectecTerminal .\n"
        "  vars N R : Nat .",
    )

    pattern = re.compile(
        r"  eq inputArgs = num\.const\(numtype\.i32, uN\.wrap\([0-9]+\)\) \."
    )
    text, count = pattern.subn(
        "  eq inputArgs(N) = num.const(numtype.i32, uN.wrap(N)) .",
        text,
        count=1,
    )
    if count != 1:
        raise RuntimeError(f"expected one inputArgs equation, replaced {count}")

    text = replace_once(
        text,
        "  crl [instantiate] : boot => init(C)\n",
        "  crl [instantiate] : boot(N) => init(N, C)\n",
    )
    text = replace_once(
        text,
        "  crl [init-step] : init(C) => init(C2)\n",
        "  crl [init-step] : init(N, C) => init(N, C2)\n",
    )
    text = replace_once(text, "    init(config.sym(", "    init(N, config.sym(")
    text = replace_once(text, "    => exec(def.invoke(", "    => exec(N, def.invoke(")
    text = replace_once(text, ", inputArgs)) .", ", inputArgs(N))) .")
    text = replace_once(
        text,
        "  crl [step] : exec(C) => exec(C2)\n",
        "  crl [step] : exec(N, C) => exec(N, C2)\n",
    )

    addition = f"""

  --- Finite boundary domain for one full-i8 PackedI8K4 position.
  rl [launch-input] : choose(N) => boot(N) .
  crl [next-input] : choose(N) => choose(N + 1) if N < {args.max} .

  op mismatch-reachable : -> Prop [ctor] .
  var X : RunState .

  eq exec(N, config.sym(S, instr.const(numtype.i32, uN.wrap(1))))
      |= mismatch-reachable = true .
  eq X |= mismatch-reachable = false [owise] .
endm

select {args.module_name} .
search [1] in {args.module_name} :
  choose({args.start}) =>* X:RunState
  such that X:RunState |= mismatch-reachable .
red in {args.module_name} :
  modelCheck(choose({args.start}), [] ~ mismatch-reachable) .
quit
"""

    text = replace_once(text, "endm\n", addition)
    args.output.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
