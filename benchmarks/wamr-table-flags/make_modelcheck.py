#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from pathlib import Path


def once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise RuntimeError(f"expected one occurrence: {old!r}")
    return text.replace(old, new, 1)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("input", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("--module-name", required=True)
    args = p.parse_args()

    text = args.input.read_text(encoding="utf-8")
    text = text.split("\nrew [", 1)[0].rstrip() + "\n"
    line = text.find("\n")
    text = text[: line + 1] + "load model-checker.maude\n\n" + text[line + 1 :]
    text = once(text, "mod WASM2MAUDE-RUN is", f"mod {args.module_name} is")
    text = once(text, "  protecting WASM-BUILTINS .",
                "  protecting WASM-BUILTINS .\n  including MODEL-CHECKER .")
    text = once(text, "  sort RunState .",
                "  sort RunState .\n  subsort RunState < State .")
    text = once(text, "  op boot : -> RunState [ctor] .",
                "  op choose : Nat -> RunState [ctor] .\n"
                "  op boot : Nat -> RunState [ctor] .")
    text = once(text, "  op init : SpectecTerminal -> RunState [ctor frozen (1)] .",
                "  op init : Nat SpectecTerminal -> RunState [ctor frozen (2)] .")
    text = once(text, "  op exec : SpectecTerminal -> RunState [ctor frozen (1)] .",
                "  op exec : Nat SpectecTerminal -> RunState [ctor frozen (2)] .")
    text = once(text, "  op inputArgs : -> SpectecTerminals .",
                "  op inputArgs : Nat -> SpectecTerminals .")
    text = once(text, "  vars C C2 S MI NAME OTHER ADDR XA : SpectecTerminal .",
                "  vars C C2 S MI NAME OTHER ADDR XA : SpectecTerminal .\n"
                "  vars N R : Nat .")
    text, n = re.subn(
        r"  eq inputArgs = num\.const\(numtype\.i32, uN\.wrap\([0-9]+\)\) \.",
        "  eq inputArgs(N) = num.const(numtype.i32, uN.wrap(N)) .",
        text,
        count=1,
    )
    if n != 1:
        raise RuntimeError("inputArgs equation not found")
    text = once(text, "  crl [instantiate] : boot => init(C)\n",
                "  crl [instantiate] : boot(N) => init(N, C)\n")
    text = once(text, "  crl [init-step] : init(C) => init(C2)\n",
                "  crl [init-step] : init(N, C) => init(N, C2)\n")
    text = once(text, "    init(config.sym(", "    init(N, config.sym(")
    text = once(text, "    => exec(def.invoke(", "    => exec(N, def.invoke(")
    text = once(text, ", inputArgs)) .", ", inputArgs(N))) .")
    text = once(text, "  crl [step] : exec(C) => exec(C2)\n",
                "  crl [step] : exec(N, C) => exec(N, C2)\n")

    tail = f'''

  rl [launch] : choose(N) => boot(N) .
  --- The official limits grammar uses only 0x00, 0x01, 0x04, and 0x05.
  --- Exploring 0..5 therefore covers all valid encodings plus the two
  --- reserved/shared encodings 0x02 and 0x03.
  crl [next] : choose(N) => choose(N + 1) if N < 5 .

  op reserved-table-flag-accepted : -> Prop [ctor] .
  var X : RunState .
  ceq exec(N, config.sym(S, instr.const(numtype.i32, uN.wrap(1))))
      |= reserved-table-flag-accepted = true
    if (N == 2) or (N == 3) .
  eq X |= reserved-table-flag-accepted = false [owise] .
endm

select {args.module_name} .
search [1] in {args.module_name} :
  choose(0) =>* X:RunState
  such that X:RunState |= reserved-table-flag-accepted .
red in {args.module_name} :
  modelCheck(choose(0), [] ~ reserved-table-flag-accepted) .
quit
'''
    text = once(text, "endm\n", tail)
    args.output.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
