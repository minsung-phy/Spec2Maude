#!/usr/bin/env python3
"""Generate an automatically scheduled whole-program model with fast closure.

The compiled NASA SpaceWasm application is left intact.  The only semantic
optimization is to classify deterministic, unobservable `rel.step` execution
between environment boundaries as equations.  This is the rewriting-logic
analogue of heating/cooling: the outer model checker stores only boot, schedule,
and terminal states, while each macro transition is still computed by the
SpecTec-derived `rel.step` relation.
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

    text = once(text, "mod WASM2MAUDE-RUN is", "mod SPACEWASM-FULL-AUTO-EQ-MC is")
    text = once(
        text,
        "  op boot : -> RunState [ctor] .",
        "  op boot : -> RunState [ctor] .\n"
        "  op ready : SpectecTerminal SpectecTerminal -> RunState "
        "[ctor frozen (1 2)] .\n"
        "  op run : Nat Nat Nat SpectecTerminal -> RunState "
        "[frozen (4)] .\n"
        "  op done : Nat Nat Nat Nat -> RunState [ctor] .\n"
        "\n"
        "  sort Event Events Slot .\n"
        "  subsort Event < Events .\n"
        "  ops attack future call : -> Event [ctor] .\n"
        "  op noEvents : -> Events [ctor] .\n"
        "  op __ : Events Events -> Events [ctor assoc comm id: noEvents] .\n"
        "  op empty : -> Slot [ctor] .\n"
        "  op some : Event -> Slot [ctor] .\n"
        "  op schedule : Events Slot Slot Slot SpectecTerminal SpectecTerminal\n"
        "    -> RunState [ctor frozen (5 6)] .\n"
        "  op eventCode : Event -> Nat .",
    )
    text = once(
        text,
        "  op exec : SpectecTerminal -> RunState [ctor frozen (1)] .\n",
        "",
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
        "  vars E0 E1 E2 N : Nat .\n"
        "  vars EV EV0 EV1 EV2 : Event .\n"
        "  var EVS : Events .",
    )

    replacement_args = (
        "  eq inputArgs(E0, E1, E2) =\n"
        "    num.const(numtype.i32, uN.wrap(E0))\n"
        "    num.const(numtype.i32, uN.wrap(E1))\n"
        "    num.const(numtype.i32, uN.wrap(E2)) .\n"
        "  eq eventCode(attack) = 0 .\n"
        "  eq eventCode(future) = 1 .\n"
        "  eq eventCode(call) = 2 .\n"
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
    new_driver = """  --- Cooling point after deterministic instantiation.
  eq init(config.sym(state.sym(S, rec.frame(LOCALS, MI)), eps)) =
    ready(S, MI) .

  --- Heating: consume one official deterministic Wasm step equationally.
  --- No SpaceWasm operation is summarized or reimplemented.
  ceq init(C) = init(C2)
    if rel.step(C) => C2 .

  --- Generic environment scheduler generated from a multiset of events.
  rl [start-environment] : ready(S, MI) =>
    schedule(attack future call, empty, empty, empty, S, MI) .
  rl [choose-first] :
    schedule(EV EVS, empty, empty, empty, S, MI) =>
    schedule(EVS, some(EV), empty, empty, S, MI) .
  rl [choose-second] :
    schedule(EV EVS, some(EV0), empty, empty, S, MI) =>
    schedule(EVS, some(EV0), some(EV), empty, S, MI) .
  rl [choose-third] :
    schedule(EV EVS, some(EV0), some(EV1), empty, S, MI) =>
    schedule(EVS, some(EV0), some(EV1), some(EV), S, MI) .
  rl [launch-program] :
    schedule(noEvents, some(EV0), some(EV1), some(EV2), S, MI) =>
    run(eventCode(EV0), eventCode(EV1), eventCode(EV2),
      def.invoke(S, findFunc(value('EXPORTS, MI), inputName),
        inputArgs(eventCode(EV0), eventCode(EV1), eventCode(EV2)))) .

  --- Cooling point at the observable i32 result.
  eq run(E0, E1, E2,
      config.sym(S, instr.const(numtype.i32, uN.wrap(N)))) =
    done(E0, E1, E2, N) .

  --- Every internal transition is still derived from generated `rel.step`,
  --- but deterministic stuttering is normalized rather than stored as states.
  ceq run(E0, E1, E2, C) = run(E0, E1, E2, C2)
    if rel.step(C) => C2 .
"""
    text = once(text, old_driver, new_driver)

    tail = r'''
endm

select SPACEWASM-FULL-AUTO-EQ-MC .
search [1] in SPACEWASM-FULL-AUTO-EQ-MC :
  boot =>* done(E0:Nat, E1:Nat, E2:Nat, 1) .
show path labels 1 .
quit
'''
    return once(text, "endm\n", tail)


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
