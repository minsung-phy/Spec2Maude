#!/usr/bin/env python3
"""Compose exact translated SpaceWasm exports with memoized heating/cooling.

The complete reachable NASA SpaceWasm implementation is compiled to one Wasm
module and translated by wasm2maude.  This script supplies only (1) a generic
finite environment scheduler and (2) a safety query.  Every implementation
transition is evaluated by the generated SpecTec-derived `rel.step` relation.

`heat` is a memoized equational closure over deterministic internal Wasm steps.
Consequently, the outer search graph stores only environment boundaries, and
common prefixes of different schedules reuse their exact computed Wasm states.
No SpaceWasm loader behavior is reimplemented or summarized here.
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


def extract_input_name(text: str) -> str:
    match = re.search(
        r"  eq inputName =\s*(.*?)\s*\.\n  eq inputArgs",
        text,
        flags=re.DOTALL,
    )
    if not match:
        raise RuntimeError("generated inputName equation not found")
    return match.group(1).strip()


def transform(init_text: str, event_text: str, bad_text: str) -> str:
    init_name = extract_input_name(init_text)
    event_name = extract_input_name(event_text)
    bad_name = extract_input_name(bad_text)

    marker = "\nrew ["
    if marker not in init_text:
        raise RuntimeError("generated final rewrite command not found")
    text = init_text.split(marker, 1)[0].rstrip() + "\n"
    text = once(text, "mod WASM2MAUDE-RUN is", "mod SPACEWASM-STATEFUL-MEMO-MC is")

    declarations = """  op boot : -> RunState [ctor] .

  sort Event Events Slot .
  subsort Event < Events .
  ops attack future call : -> Event [ctor] .
  op noEvents : -> Events [ctor] .
  op __ : Events Events -> Events [ctor assoc comm id: noEvents] .
  op empty : -> Slot [ctor] .
  op some : Event -> Slot [ctor] .

  op heat : SpectecTerminal -> SpectecTerminal [memo] .
  op awaitReady : SpectecTerminal -> RunState .
  op awaitInit : SpectecTerminal SpectecTerminal -> RunState .
  op awaitEvent : Events Slot Slot Slot SpectecTerminal SpectecTerminal
    -> RunState .
  op awaitBad : Event Event Event SpectecTerminal SpectecTerminal
    -> RunState .

  op ready : SpectecTerminal SpectecTerminal -> RunState [ctor frozen (1 2)] .
  op schedule : Events Slot Slot Slot SpectecTerminal SpectecTerminal
    -> RunState [ctor frozen (5 6)] .
  op done : Event Event Event Nat -> RunState [ctor] .

  op eventCode : Event -> Nat .
  ops initName eventName badName : -> SpectecTerminal ."""
    text = once(text, "  op boot : -> RunState [ctor] .", declarations)
    text = once(text, "  op exec : SpectecTerminal -> RunState [ctor frozen (1)] .\n", "")
    text = once(
        text,
        "  vars C C2 S MI NAME OTHER ADDR XA : SpectecTerminal .",
        "  vars C C2 S MI NAME OTHER ADDR XA : SpectecTerminal .\n"
        "  vars LOCALS : SpectecTerminal .\n"
        "  vars N STATUS : Nat .\n"
        "  vars EV EV0 EV1 EV2 : Event .\n"
        "  var EVS : Events .\n"
        "  vars SL0 SL1 SL2 : Slot .",
    )

    names_and_codes = (
        f"  eq initName = {init_name} .\n"
        f"  eq eventName = {event_name} .\n"
        f"  eq badName = {bad_name} .\n"
        "  eq eventCode(attack) = 0 .\n"
        "  eq eventCode(future) = 1 .\n"
        "  eq eventCode(call) = 2 .\n"
        "  eq emptyStore"
    )
    text, count = re.subn(r"  eq emptyStore", names_and_codes, text, count=1)
    if count != 1:
        raise RuntimeError("emptyStore equation not found")

    old_driver = """  crl [init-step] : init(C) => init(C2)
    if rel.step(C) => C2 .
  rl [invoke] :
    init(config.sym(state.sym(S, rec.frame(LOCALS, MI)), eps))
    => exec(def.invoke(
      S, findFunc(value('EXPORTS, MI), inputName), inputArgs)) .
  crl [step] : exec(C) => exec(C2)
    if rel.step(C) => C2 .
"""

    new_driver = """  --- Memoized heating closure over generated official Wasm steps.
  --- The two equations below are the only cooling points needed by this
  --- application: a fully instantiated module and an exported i32 return.
  eq heat(config.sym(state.sym(S, rec.frame(LOCALS, MI)), eps)) =
    config.sym(state.sym(S, rec.frame(LOCALS, MI)), eps) .
  eq heat(config.sym(S, instr.const(numtype.i32, uN.wrap(N)))) =
    config.sym(S, instr.const(numtype.i32, uN.wrap(N))) .
  ceq heat(C) = heat(C2)
    if rel.step(C) => C2 .

  --- Automatically translated module instantiation.
  eq init(C) = awaitReady(heat(C)) .
  eq awaitReady(config.sym(state.sym(S, rec.frame(LOCALS, MI)), eps)) =
    ready(S, MI) .

  --- Initialize the exact SpaceWasm Engine once in the translated Wasm store.
  rl [initialize-spacewasm] : ready(S, MI) =>
    awaitInit(MI, heat(def.invoke(S,
      findFunc(value('EXPORTS, MI), initName), eps))) .
  eq awaitInit(MI,
      config.sym(S, instr.const(numtype.i32, uN.wrap(0)))) =
    schedule(attack future call, empty, empty, empty, S, MI) .

  --- AC matching chooses an arbitrary remaining event.  This generic model
  --- generates every permutation and calls the exact production export.
  rl [choose-first] :
    schedule(EV EVS, empty, empty, empty, S, MI) =>
    awaitEvent(EVS, some(EV), empty, empty, MI,
      heat(def.invoke(S, findFunc(value('EXPORTS, MI), eventName),
        num.const(numtype.i32, uN.wrap(eventCode(EV)))))) .
  rl [choose-second] :
    schedule(EV EVS, some(EV0), empty, empty, S, MI) =>
    awaitEvent(EVS, some(EV0), some(EV), empty, MI,
      heat(def.invoke(S, findFunc(value('EXPORTS, MI), eventName),
        num.const(numtype.i32, uN.wrap(eventCode(EV)))))) .
  rl [choose-third] :
    schedule(EV EVS, some(EV0), some(EV1), empty, S, MI) =>
    awaitEvent(EVS, some(EV0), some(EV1), some(EV), MI,
      heat(def.invoke(S, findFunc(value('EXPORTS, MI), eventName),
        num.const(numtype.i32, uN.wrap(eventCode(EV)))))) .

  eq awaitEvent(EVS, some(EV0), empty, empty, MI,
      config.sym(S, instr.const(numtype.i32, uN.wrap(STATUS)))) =
    schedule(EVS, some(EV0), empty, empty, S, MI) .
  eq awaitEvent(EVS, some(EV0), some(EV1), empty, MI,
      config.sym(S, instr.const(numtype.i32, uN.wrap(STATUS)))) =
    schedule(EVS, some(EV0), some(EV1), empty, S, MI) .
  eq awaitEvent(EVS, some(EV0), some(EV1), some(EV2), MI,
      config.sym(S, instr.const(numtype.i32, uN.wrap(STATUS)))) =
    schedule(EVS, some(EV0), some(EV1), some(EV2), S, MI) .

  --- Query the exact application monitor after all external events.
  rl [check-safety-property] :
    schedule(noEvents, some(EV0), some(EV1), some(EV2), S, MI) =>
    awaitBad(EV0, EV1, EV2, MI,
      heat(def.invoke(S, findFunc(value('EXPORTS, MI), badName), eps))) .
  eq awaitBad(EV0, EV1, EV2, MI,
      config.sym(S, instr.const(numtype.i32, uN.wrap(N)))) =
    done(EV0, EV1, EV2, N) .
"""
    text = once(text, old_driver, new_driver)

    tail = r'''
endm

select SPACEWASM-STATEFUL-MEMO-MC .
search [1] in SPACEWASM-STATEFUL-MEMO-MC :
  boot =>* done(E0:Event, E1:Event, E2:Event, 1) .
show path labels 1 .
quit
'''
    return once(text, "endm\n", tail)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("init_run", type=Path)
    parser.add_argument("event_run", type=Path)
    parser.add_argument("bad_run", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_text(
        transform(
            args.init_run.read_text(encoding="utf-8"),
            args.event_run.read_text(encoding="utf-8"),
            args.bad_run.read_text(encoding="utf-8"),
        ),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
