#!/usr/bin/env python3
"""Compose exact translated SpaceWasm exports into a persistent event model."""

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
    text = once(text, "mod WASM2MAUDE-RUN is", "mod SPACEWASM-STATEFUL-FULL-MC is")

    declarations = """  op boot : -> RunState [ctor] .

  sort Event Events Slot .
  subsort Event < Events .
  ops attack future call : -> Event [ctor] .
  op noEvents : -> Events [ctor] .
  op __ : Events Events -> Events [ctor assoc comm id: noEvents] .
  op empty : -> Slot [ctor] .
  op some : Event -> Slot [ctor] .

  op ready : SpectecTerminal SpectecTerminal -> RunState [ctor frozen (1 2)] .
  op runInit : SpectecTerminal SpectecTerminal -> RunState [frozen (1 2)] .
  op schedule : Events Slot Slot Slot SpectecTerminal SpectecTerminal
    -> RunState [ctor frozen (5 6)] .
  op runEvent : Events Slot Slot Slot SpectecTerminal SpectecTerminal
    -> RunState [frozen (5 6)] .
  op runBad : Event Event Event SpectecTerminal SpectecTerminal
    -> RunState [frozen (4 5)] .
  op done : Event Event Event Nat -> RunState [ctor] .

  op eventCode : Event -> Nat .
  ops initName eventName badName : -> SpectecTerminal ."""
    text = once(text, "  op boot : -> RunState [ctor] .", declarations)
    text = once(text, "  op exec : SpectecTerminal -> RunState [ctor frozen (1)] .\n", "")
    text = once(
        text,
        "  vars C C2 S MI NAME OTHER ADDR XA : SpectecTerminal .",
        "  vars C C2 S MI NAME OTHER ADDR XA : SpectecTerminal .\n"
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
    new_driver = """  --- Deterministic module instantiation is heated equationally.
  eq init(config.sym(state.sym(S, rec.frame(LOCALS, MI)), eps)) =
    ready(S, MI) .
  ceq init(C) = init(C2)
    if rel.step(C) => C2 .

  --- Initialize the exact NASA SpaceWasm engine once.
  rl [initialize-spacewasm] : ready(S, MI) =>
    runInit(MI, def.invoke(S,
      findFunc(value('EXPORTS, MI), initName), eps)) .
  eq runInit(MI,
      config.sym(S, instr.const(numtype.i32, uN.wrap(0)))) =
    schedule(attack future call, empty, empty, empty, S, MI) .
  ceq runInit(MI, C) = runInit(MI, C2)
    if rel.step(C) => C2 .

  --- AC matching automatically chooses every remaining external event.
  rl [choose-first] :
    schedule(EV EVS, empty, empty, empty, S, MI) =>
    runEvent(EVS, some(EV), empty, empty, MI,
      def.invoke(S, findFunc(value('EXPORTS, MI), eventName),
        num.const(numtype.i32, uN.wrap(eventCode(EV))))) .
  rl [choose-second] :
    schedule(EV EVS, some(EV0), empty, empty, S, MI) =>
    runEvent(EVS, some(EV0), some(EV), empty, MI,
      def.invoke(S, findFunc(value('EXPORTS, MI), eventName),
        num.const(numtype.i32, uN.wrap(eventCode(EV))))) .
  rl [choose-third] :
    schedule(EV EVS, some(EV0), some(EV1), empty, S, MI) =>
    runEvent(EVS, some(EV0), some(EV1), some(EV), MI,
      def.invoke(S, findFunc(value('EXPORTS, MI), eventName),
        num.const(numtype.i32, uN.wrap(eventCode(EV))))) .

  eq runEvent(EVS, some(EV0), empty, empty, MI,
      config.sym(S, instr.const(numtype.i32, uN.wrap(STATUS)))) =
    schedule(EVS, some(EV0), empty, empty, S, MI) .
  eq runEvent(EVS, some(EV0), some(EV1), empty, MI,
      config.sym(S, instr.const(numtype.i32, uN.wrap(STATUS)))) =
    schedule(EVS, some(EV0), some(EV1), empty, S, MI) .
  eq runEvent(EVS, some(EV0), some(EV1), some(EV2), MI,
      config.sym(S, instr.const(numtype.i32, uN.wrap(STATUS)))) =
    schedule(EVS, some(EV0), some(EV1), some(EV2), S, MI) .
  ceq runEvent(EVS, SL0, SL1, SL2, MI, C) =
      runEvent(EVS, SL0, SL1, SL2, MI, C2)
    if rel.step(C) => C2 .

  --- Query the production safety monitor after the selected permutation.
  rl [check-safety-property] :
    schedule(noEvents, some(EV0), some(EV1), some(EV2), S, MI) =>
    runBad(EV0, EV1, EV2, MI,
      def.invoke(S, findFunc(value('EXPORTS, MI), badName), eps)) .
  eq runBad(EV0, EV1, EV2, MI,
      config.sym(S, instr.const(numtype.i32, uN.wrap(N)))) =
    done(EV0, EV1, EV2, N) .
  ceq runBad(EV0, EV1, EV2, MI, C) =
      runBad(EV0, EV1, EV2, MI, C2)
    if rel.step(C) => C2 .
"""
    text = once(text, old_driver, new_driver)

    tail = r'''
endm

select SPACEWASM-STATEFUL-FULL-MC .
search [1] in SPACEWASM-STATEFUL-FULL-MC :
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
