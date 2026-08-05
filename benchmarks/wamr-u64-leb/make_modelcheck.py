#!/usr/bin/env python3
"""Turn a generated wasm2maude concrete run into a bounded input model.

The generated module and invocation machinery remain those emitted by
wasm2maude.  This script only threads the candidate final LEB byte through the
run state and adds a finite nondeterministic chooser plus an LTL proposition.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def replace_once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"expected exactly one occurrence, got {count}: {old!r}")
    return text.replace(old, new, 1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--module-name", required=True)
    parser.add_argument("--max-last", type=int, default=127)
    args = parser.parse_args()

    text = args.input.read_text(encoding="utf-8")
    marker = "\nrew ["
    if marker not in text:
        raise RuntimeError("generated run command marker was not found")
    text = text.split(marker, 1)[0].rstrip() + "\n"

    first_newline = text.find("\n")
    if first_newline < 0:
        raise RuntimeError("generated file has no load line")
    text = (
        text[: first_newline + 1]
        + "load model-checker.maude\n\n"
        + text[first_newline + 1 :]
    )

    text = replace_once(
        text, "mod WASM2MAUDE-RUN is", f"mod {args.module_name} is"
    )
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
        "  eq inputArgs(N) = num.const(numtype.i32, uN.wrap(N)) .", text, count=1
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

  --- Finite branching over every possible terminal payload byte of a
  --- ten-byte u64 LEB.  The first nine bytes are fixed to 0x80 in the actual
  --- compiled WAMR wrapper.
  rl [launch-input] : choose(N) => boot(N) .
  crl [next-input] : choose(N) => choose(N + 1)
    if N < {args.max_last} .

  op u64-overflow-accepted : -> Prop [ctor] .
  var X : RunState .

  --- For a ten-byte u64 LEB, only terminal payloads 0 and 1 are legal.  WAMR's
  --- enum value 0 is BH_LEB_READ_SUCCESS.
  ceq exec(N,
      config.sym(S, instr.const(numtype.i32, uN.wrap(0))))
      |= u64-overflow-accepted = true
    if 1 < N .
  eq X |= u64-overflow-accepted = false [owise] .
endm

select {args.module_name} .

search [1] in {args.module_name} :
  choose(0) =>* X:RunState
  such that X:RunState |= u64-overflow-accepted .

red in {args.module_name} :
  modelCheck(choose(0), [] ~ u64-overflow-accepted) .

quit
"""

    text = replace_once(text, "endm\n", addition)
    args.output.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
