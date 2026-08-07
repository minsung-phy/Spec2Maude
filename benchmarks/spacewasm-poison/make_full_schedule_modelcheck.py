#!/usr/bin/env python3
"""Model check the exact compiled SpaceWasm implementation.

No SpaceWasm loader transition is reimplemented in Maude.  The production Rust
library plus a generic three-event driver is compiled to Wasm and translated by
`wasm2maude`.  This script adds only (1) a generic nondeterministic permutation
scheduler and (2) the observable contract that the provider must still return
7.  All program behavior is computed by the generated SpecTec semantics.

The generated `rel.step` relation is unchanged.  Deterministic internal Wasm
execution is hidden through the generated official reflexive-transitive
`rel.steps` relation, removing stuttering states without changing results.
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

    text = once(text, "mod WASM2MAUDE-RUN is", "mod SPACEWASM-FULL-SCHEDULE-MC is")
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
        "  op boot : -> RunState [ctor] .\n"
        "  op ready : SpectecTerminal SpectecTerminal -> RunState "
        "[ctor frozen (1 2)] .\n"
        "  op picked : Nat SpectecTerminal SpectecTerminal -> RunState "
        "[ctor frozen (2 3)] .\n"
        "  op done : Nat Nat Nat Nat -> RunState [ctor] .",
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
        "  vars E0 E1 E2 N : Nat .",
    )

    replacement_args = (
        "  eq inputArgs(E0, E1, E2) =\n"
        "    num.const(numtype.i32, uN.wrap(E0))\n"
        "    num.const(numtype.i32, uN.wrap(E1))\n"
        "    num.const(numtype.i32, uN.wrap(E2)) .\n"
        "  eq emptyStore"
    )
    text, count = re.subn(
        r"  eq inputArgs = .*? \.[ \t]*\n  eq emptyStore",
        replacement_args,
        text,
        count=1,
        flags=re.DOTALL,
    )
    if count != 1:
        raise RuntimeError("inputArgs equation not found")

    old_driver = """  crl [init-step] : init(C) => init(C2)
    if rel.step(C) => C2 .
  rl [invoke] :
    init(config.sym(state.sym(S, rec.frame(LOCALS, MI)), eps))
    => exec(def.invoke(
      S, findFunc(value('EXPORTS, MI), inputName), inputArgs)) .
  crl [step] : exec(C) => exec(C2)
    if rel.step(C) => C2 .
"""
    new_driver = """  --- Complete deterministic module initialization once.
  crl [init-macro] : init(C) => ready(S, MI)
    if rel.steps(C) =>
      config.sym(state.sym(S, rec.frame(LOCALS, MI)), eps) .

  --- Generic event scheduler.  The first event is chosen nondeterministically;
  --- the second is any different event; the third is the unique remaining
  --- member of {0,1,2}, computed from their fixed sum 3.  Thus all 3! schedules
  --- are generated without encoding six bug-specific traces.
  rl [pick-first-attacker] : ready(S, MI) => picked(0, S, MI) .
  rl [pick-first-future]   : ready(S, MI) => picked(1, S, MI) .
  rl [pick-first-call]     : ready(S, MI) => picked(2, S, MI) .

  crl [pick-second-attacker] : picked(E0, S, MI) =>
    exec(E0, 0, (3 - E0) - 0, def.invoke(S,
      findFunc(value('EXPORTS, MI), inputName),
      inputArgs(E0, 0, (3 - E0) - 0)))
    if not (E0 == 0) .
  crl [pick-second-future] : picked(E0, S, MI) =>
    exec(E0, 1, (3 - E0) - 1, def.invoke(S,
      findFunc(value('EXPORTS, MI), inputName),
      inputArgs(E0, 1, (3 - E0) - 1)))
    if not (E0 == 1) .
  crl [pick-second-call] : picked(E0, S, MI) =>
    exec(E0, 2, (3 - E0) - 2, def.invoke(S,
      findFunc(value('EXPORTS, MI), inputName),
      inputArgs(E0, 2, (3 - E0) - 2)))
    if not (E0 == 2) .

  --- `def.invoke` needs its first official step; all remaining deterministic
  --- execution is closed by generated `rel.steps`.  No production `rel.step`
  --- rule or SpaceWasm operation is replaced by a handwritten transition.
  crl [exec-macro] :
    exec(E0, E1, E2, C) => done(E0, E1, E2, N)
    if rel.step(C) => C2 /\\
       rel.steps(C2) =>
         config.sym(S, instr.const(numtype.i32, uN.wrap(N))) .
"""
    text = once(text, old_driver, new_driver)

    tail = r'''

  --- The public contract is independent of the known exploit constant:
  --- provider.call must return its original value 7 under every event order.
  op wrong-provider-result : -> Prop [ctor] .
  var X : RunState .
  ceq done(E0, E1, E2, N) |= wrong-provider-result = true
    if not (N == 7) .
  eq X |= wrong-provider-result = false [owise] .
endm

select SPACEWASM-FULL-SCHEDULE-MC .
search [1] in SPACEWASM-FULL-SCHEDULE-MC :
  boot =>* X:RunState
  such that X:RunState |= wrong-provider-result .
show path labels 1 .
red in SPACEWASM-FULL-SCHEDULE-MC :
  modelCheck(boot, [] ~ wrong-provider-result) .
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
