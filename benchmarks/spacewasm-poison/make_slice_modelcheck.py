#!/usr/bin/env python3
"""Turn a wasm2maude `run` wrapper for `run3` into a Maude model checker.

The generated SpecTec-derived WebAssembly semantics and its `rel.step` rules
remain unchanged.  This wrapper adds only the externally observable scheduler:
all six permutations of rejected partial load (0), future valid load (1), and
provider call_indirect (2).
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"expected exactly one occurrence, found {count}: {old!r}")
    return text.replace(old, new, 1)


def transform(text: str) -> str:
    # Remove the concrete command emitted by wasm2maude; the module itself is
    # retained verbatim and generalized below.
    marker = "\nrew ["
    if marker not in text:
        raise RuntimeError("generated final rewrite command not found")
    text = text.split(marker, 1)[0].rstrip() + "\n"

    first_newline = text.find("\n")
    if first_newline < 0:
        raise RuntimeError("generated load command not found")
    text = (
        text[: first_newline + 1]
        + "load model-checker.maude\n\n"
        + text[first_newline + 1 :]
    )

    text = once(text, "mod WASM2MAUDE-RUN is", "mod SPACEWASM-SLICE-MC is")
    text = once(
        text,
        "  protecting WASM-BUILTINS .",
        "  protecting WASM-BUILTINS .\n  including MODEL-CHECKER .",
    )
    text = once(
        text,
        "  sort RunState .",
        "  sort RunState .\n  subsort RunState < State .",
    )
    text = once(
        text,
        "  op boot : -> RunState [ctor] .",
        "  op choose : -> RunState [ctor] .\n"
        "  op boot : Nat Nat Nat -> RunState [ctor] .",
    )
    text = once(
        text,
        "  op init : SpectecTerminal -> RunState [ctor frozen (1)] .",
        "  op init : Nat Nat Nat SpectecTerminal -> RunState [ctor frozen (4)] .",
    )
    text = once(
        text,
        "  op exec : SpectecTerminal -> RunState [ctor frozen (1)] .",
        "  op exec : Nat Nat Nat SpectecTerminal -> RunState [ctor frozen (4)] .",
    )
    text = once(
        text,
        "  op inputArgs : -> SpectecTerminals .",
        "  op inputArgs : Nat Nat Nat -> SpectecTerminals .",
    )
    text = once(
        text,
        "  vars C C2 S MI NAME OTHER ADDR XA : SpectecTerminal .",
        "  vars C C2 S MI NAME OTHER ADDR XA : SpectecTerminal .\n"
        "  vars E0 E1 E2 : Nat .",
    )

    args_eq = (
        "  eq inputArgs(E0, E1, E2) =\n"
        "    num.const(numtype.i32, uN.wrap(E0))\n"
        "    num.const(numtype.i32, uN.wrap(E1))\n"
        "    num.const(numtype.i32, uN.wrap(E2)) .\n"
        "  eq emptyStore"
    )
    text, count = re.subn(
        r"  eq inputArgs = .*? \.[ \t]*\n  eq emptyStore",
        args_eq,
        text,
        count=1,
        flags=re.DOTALL,
    )
    if count != 1:
        raise RuntimeError("inputArgs equation not found")

    text = once(
        text,
        "  crl [instantiate] : boot => init(C)\n",
        "  crl [instantiate] : boot(E0, E1, E2) => init(E0, E1, E2, C)\n",
    )
    text = once(
        text,
        "  crl [init-step] : init(C) => init(C2)\n",
        "  crl [init-step] : init(E0, E1, E2, C) => init(E0, E1, E2, C2)\n",
    )
    text = once(
        text,
        "    init(config.sym(",
        "    init(E0, E1, E2, config.sym(",
    )
    text = once(
        text,
        "    => exec(def.invoke(\n",
        "    => exec(E0, E1, E2, def.invoke(\n",
    )
    text = once(text, ", inputArgs)) .", ", inputArgs(E0, E1, E2))) .")
    text = once(
        text,
        "  crl [step] : exec(C) => exec(C2)\n",
        "  crl [step] : exec(E0, E1, E2, C) => exec(E0, E1, E2, C2)\n",
    )

    tail = r'''

  --- 0 = rejected partial load, 1 = later valid load, 2 = provider call.
  --- Exactly one rule is chosen at the initial state; together these rules
  --- enumerate the complete bounded schedule space (3! = 6).
  rl [order-attack-future-call] : choose => boot(0, 1, 2) .
  rl [order-attack-call-future] : choose => boot(0, 2, 1) .
  rl [order-future-attack-call] : choose => boot(1, 0, 2) .
  rl [order-future-call-attack] : choose => boot(1, 2, 0) .
  rl [order-call-attack-future] : choose => boot(2, 0, 1) .
  rl [order-call-future-attack] : choose => boot(2, 1, 0) .

  op private-function-hijacked : -> Prop [ctor] .
  var X : RunState .
  eq exec(E0, E1, E2,
      config.sym(S, instr.const(numtype.i32, uN.wrap(1))))
      |= private-function-hijacked = true .
  eq X |= private-function-hijacked = false [owise] .
endm

select SPACEWASM-SLICE-MC .
search [1] in SPACEWASM-SLICE-MC :
  choose =>* X:RunState
  such that X:RunState |= private-function-hijacked .
show path labels 1 .
red in SPACEWASM-SLICE-MC :
  modelCheck(choose, [] ~ private-function-hijacked) .
quit
'''
    text = once(text, "endm\n", tail)
    return text


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_text(
        transform(args.input.read_text(encoding="utf-8")), encoding="utf-8"
    )


if __name__ == "__main__":
    main()
