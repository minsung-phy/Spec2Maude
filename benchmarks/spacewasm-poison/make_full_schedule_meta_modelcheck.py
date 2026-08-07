#!/usr/bin/env python3
"""Generate an automatic exact-SpaceWasm model using Maude reflection.

`wasm2maude` supplies the complete executable model of all SpaceWasm production
code reachable from `spacewasm_run3`.  This transformation does not encode any
loader behavior.  It only:

1. parameterizes the generated invocation by three environment events;
2. uses `metaRewrite` as a deterministic macro evaluator for a fixed schedule;
3. adds a generic permutation scheduler and the public result contract.

Because WebAssembly execution for a fixed input is deterministic here,
`metaRewrite` is a stuttering reduction of the generated `rel.step` execution,
not an abstraction of SpaceWasm state or behavior.
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

    text = once(text, "mod WASM2MAUDE-RUN is", "mod SPACEWASM-EXACT-EVAL is")
    text = once(
        text,
        "  op boot : -> RunState [ctor] .",
        "  op boot : Nat Nat Nat -> RunState [ctor] .",
    )
    text = once(
        text,
        "  op init : SpectecTerminal -> RunState [ctor frozen (1)] .",
        "  op init : Nat Nat Nat SpectecTerminal -> RunState [ctor frozen (4)] .",
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
        "    init(config.sym(state.sym(S, rec.frame(LOCALS, MI)), eps))\n"
        "    => exec(def.invoke(\n"
        "      S, findFunc(value('EXPORTS, MI), inputName), inputArgs)) .",
        "    init(E0, E1, E2,\n"
        "      config.sym(state.sym(S, rec.frame(LOCALS, MI)), eps))\n"
        "    => exec(def.invoke(\n"
        "      S, findFunc(value('EXPORTS, MI), inputName),\n"
        "      inputArgs(E0, E1, E2))) .",
    )

    outer = r'''

mod SPACEWASM-EXACT-AUTO-MC is
  protecting SPACEWASM-EXACT-EVAL .
  --- META-LEVEL imports the predefined generic list concatenation operator
  --- `__`, while the generated SpecTec syntax also defines `__` with distinct
  --- attributes. Rename the metalevel copy so both executable theories can be
  --- composed without changing either theory's equations.
  protecting META-LEVEL * (op __ to _metaConcat_) .
  including MODEL-CHECKER .

  sort MCState .
  subsort MCState < State .

  op initial : -> MCState [ctor] .
  op picked : Nat -> MCState [ctor] .
  op observed : Nat Nat Nat RunState -> MCState [ctor frozen (4)] .

  vars E0 E1 E2 N : Nat .
  vars C S : SpectecTerminal .
  var X : MCState .

  --- Run the exact automatically generated implementation model to its normal
  --- form for one fixed event schedule.  This is Maude's ordinary rewrite
  --- strategy applied reflectively to SPACEWASM-EXACT-EVAL.
  op exactRun : Nat Nat Nat -> RunState .
  eq exactRun(E0, E1, E2) =
    downTerm(
      getTerm(
        metaRewrite(
          upModule('SPACEWASM-EXACT-EVAL, false),
          upTerm(boot(E0, E1, E2)),
          unbounded)),
      boot(E0, E1, E2)) .

  --- Generic permutation generator over event IDs {0,1,2}.
  rl [pick-first-attacker] : initial => picked(0) .
  rl [pick-first-future]   : initial => picked(1) .
  rl [pick-first-call]     : initial => picked(2) .

  crl [pick-second-attacker] : picked(E0) =>
    observed(E0, 0, (3 - E0) - 0, exactRun(E0, 0, (3 - E0) - 0))
    if not (E0 == 0) .
  crl [pick-second-future] : picked(E0) =>
    observed(E0, 1, (3 - E0) - 1, exactRun(E0, 1, (3 - E0) - 1))
    if not (E0 == 1) .
  crl [pick-second-call] : picked(E0) =>
    observed(E0, 2, (3 - E0) - 2, exactRun(E0, 2, (3 - E0) - 2))
    if not (E0 == 2) .

  --- Public, exploit-independent contract: after the three environment events,
  --- provider.call must still return its original value 7.
  op wrong-provider-result : -> Prop [ctor] .
  ceq observed(E0, E1, E2,
        exec(config.sym(S, instr.const(numtype.i32, uN.wrap(N)))))
      |= wrong-provider-result = true
    if not (N == 7) .
  eq X |= wrong-provider-result = false [owise] .
endm

select SPACEWASM-EXACT-AUTO-MC .
red in SPACEWASM-EXACT-AUTO-MC : exactRun(0, 1, 2) .
red in SPACEWASM-EXACT-AUTO-MC : exactRun(2, 0, 1) .
search [1] in SPACEWASM-EXACT-AUTO-MC :
  initial =>* X:MCState
  such that X:MCState |= wrong-provider-result .
show path labels 1 .
red in SPACEWASM-EXACT-AUTO-MC :
  modelCheck(initial, [] ~ wrong-provider-result) .
quit
'''

    text = once(text, "endm\n", "endm\n" + outer)
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
