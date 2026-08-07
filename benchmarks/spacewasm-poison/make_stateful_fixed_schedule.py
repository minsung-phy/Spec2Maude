#!/usr/bin/env python3
"""Generate one deterministic macro execution of the exact translated app."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"expected exactly one occurrence, found {count}: {old!r}")
    return text.replace(old, new, 1)


def name_of(text: str) -> str:
    m = re.search(r"  eq inputName =\s*(.*?)\s*\.\n  eq inputArgs", text, re.DOTALL)
    if not m:
        raise RuntimeError("inputName not found")
    return m.group(1).strip()


def transform(init_text: str, event_text: str, bad_text: str, events: tuple[int, int, int]) -> str:
    names = tuple(map(name_of, (init_text, event_text, bad_text)))
    marker = "\nrew ["
    text = init_text.split(marker, 1)[0].rstrip() + "\n"
    text = once(text, "mod WASM2MAUDE-RUN is", "mod SPACEWASM-FIXED-MACRO is")
    declarations = """  op boot : -> RunState [ctor] .
  op ready : SpectecTerminal SpectecTerminal -> RunState [ctor frozen (1 2)] .
  op runInit : SpectecTerminal SpectecTerminal -> RunState [frozen (1 2)] .
  op run0 : SpectecTerminal SpectecTerminal -> RunState [frozen (1 2)] .
  op run1 : SpectecTerminal SpectecTerminal -> RunState [frozen (1 2)] .
  op run2 : SpectecTerminal SpectecTerminal -> RunState [frozen (1 2)] .
  op runBad : SpectecTerminal SpectecTerminal -> RunState [frozen (1 2)] .
  op done : Nat -> RunState [ctor] .
  ops initName eventName badName : -> SpectecTerminal ."""
    text = once(text, "  op boot : -> RunState [ctor] .", declarations)
    text = once(text, "  op exec : SpectecTerminal -> RunState [ctor frozen (1)] .\n", "")
    text = once(
        text,
        "  vars C C2 S MI NAME OTHER ADDR XA : SpectecTerminal .",
        "  vars C C2 S MI NAME OTHER ADDR XA : SpectecTerminal .\n  vars N STATUS : Nat .",
    )
    extra = (
        f"  eq initName = {names[0]} .\n"
        f"  eq eventName = {names[1]} .\n"
        f"  eq badName = {names[2]} .\n"
        "  eq emptyStore"
    )
    text, count = re.subn(r"  eq emptyStore", extra, text, count=1)
    if count != 1:
        raise RuntimeError("emptyStore not found")

    e0, e1, e2 = events
    old_driver = """  crl [init-step] : init(C) => init(C2)
    if rel.step(C) => C2 .
  rl [invoke] :
    init(config.sym(state.sym(S, rec.frame(LOCALS, MI)), eps))
    => exec(def.invoke(
      S, findFunc(value('EXPORTS, MI), inputName), inputArgs)) .
  crl [step] : exec(C) => exec(C2)
    if rel.step(C) => C2 .
"""
    new_driver = f"""  eq init(config.sym(state.sym(S, rec.frame(LOCALS, MI)), eps)) = ready(S, MI) .
  ceq init(C) = init(C2) if rel.step(C) => C2 .

  rl [call-init] : ready(S, MI) =>
    runInit(MI, def.invoke(S, findFunc(value('EXPORTS, MI), initName), eps)) .
  eq runInit(MI, config.sym(S, instr.const(numtype.i32, uN.wrap(0)))) =
    run0(MI, def.invoke(S, findFunc(value('EXPORTS, MI), eventName),
      num.const(numtype.i32, uN.wrap({e0})))) .
  ceq runInit(MI, C) = runInit(MI, C2) if rel.step(C) => C2 .

  eq run0(MI, config.sym(S, instr.const(numtype.i32, uN.wrap(STATUS)))) =
    run1(MI, def.invoke(S, findFunc(value('EXPORTS, MI), eventName),
      num.const(numtype.i32, uN.wrap({e1})))) .
  ceq run0(MI, C) = run0(MI, C2) if rel.step(C) => C2 .

  eq run1(MI, config.sym(S, instr.const(numtype.i32, uN.wrap(STATUS)))) =
    run2(MI, def.invoke(S, findFunc(value('EXPORTS, MI), eventName),
      num.const(numtype.i32, uN.wrap({e2})))) .
  ceq run1(MI, C) = run1(MI, C2) if rel.step(C) => C2 .

  eq run2(MI, config.sym(S, instr.const(numtype.i32, uN.wrap(STATUS)))) =
    runBad(MI, def.invoke(S, findFunc(value('EXPORTS, MI), badName), eps)) .
  ceq run2(MI, C) = run2(MI, C2) if rel.step(C) => C2 .

  eq runBad(MI, config.sym(S, instr.const(numtype.i32, uN.wrap(N)))) = done(N) .
  ceq runBad(MI, C) = runBad(MI, C2) if rel.step(C) => C2 .
"""
    text = once(text, old_driver, new_driver)
    tail = """
endm

select SPACEWASM-FIXED-MACRO .
rew [10] in SPACEWASM-FIXED-MACRO : boot .
quit
"""
    return once(text, "endm\n", tail)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("init_run", type=Path)
    p.add_argument("event_run", type=Path)
    p.add_argument("bad_run", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("events", nargs=3, type=int)
    a = p.parse_args()
    a.output.write_text(
        transform(
            a.init_run.read_text(),
            a.event_run.read_text(),
            a.bad_run.read_text(),
            tuple(a.events),
        )
    )


if __name__ == "__main__":
    main()
