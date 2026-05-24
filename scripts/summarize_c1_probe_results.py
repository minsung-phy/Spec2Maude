#!/usr/bin/env python3
"""Summarize the C1 Maude probe suite.

This script intentionally checks concrete representative probes, not the
infinite space of all possible Maude terms.  It treats known direct-query
limitations as expected stuck results, and reports regressions when accepted
probes no longer produce the expected result.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


Probe = tuple[str, str, str, str]


PROBES: list[Probe] = [
    ("PASS", "index-empty", "index(CTORI32A0 CTORI64A0, eps)", "result Nonfuncs: eps"),
    ("PASS", "index-sequence", "index(CTORI32A0 CTORI64A0, 0 1)", "result Nonfuncs: CTORI32A0 CTORI64A0"),
    ("PASS", "index-locals-empty", "index(value('LOCALS, C0), eps)", "result Nonfuncs: eps"),
    ("PASS", "resulttype-ok-empty", "Resulttype-ok(C0, eps)", "result ValidJudgement: valid"),
    ("PASS", "resulttype-ok-multi", "Resulttype-ok(C0, CTORI32A0 CTORI32A0)", "result ValidJudgement: valid"),
    ("PASS", "resulttype-sub-empty", "Resulttype-sub(C0, eps, eps)", "result ValidJudgement: valid"),
    ("PASS", "instrtype-ok-empty-arrow", "Instrtype-ok(C0, CTORARROWA3(eps, eps, eps))", "result ValidJudgement: valid"),
    ("PASS", "instrtype-sub-empty-arrow", "Instrtype-sub(C0, CTORARROWA3(eps, eps, eps)", "result ValidJudgement: valid"),
    ("PASS", "instr-ok-unreachable", "Instr-ok(C0, CTORUNREACHABLEA0", "result ValidJudgement: valid"),
    ("PASS", "externaddr-ok-fib", "Externaddr-ok(fib-store, CTORFUNCA1(0)", "result ValidJudgement: valid"),
    ("PASS", "instrs-ok-seq-nop", "Instrs-ok(C0, CTORNOPA0", "result ValidJudgement: valid"),
    ("PASS", "expr-ok-nop", "Expr-ok(C0, CTORNOPA0, eps)", "result ValidJudgement: valid"),
    ("PASS", "val-oks-empty-sequence", "Val-oks(fib-store, eps, eps)", "result ValidJudgement: valid"),
    ("PASS", "val-oks-multi-sequence", "Val-oks(fib-store, CTORCONSTA2(CTORI32A0, 5)", "result ValidJudgement: valid"),
    ("PASS", "invoke-rewrites-to-config", "$invoke(fib-store, 0", "result Config:"),
    ("KNOWN_STUCK", "steps-invoke-outer-config", "steps(invoke-outer-config)", "CTORFRAMELBRACERBRACEA3"),
    ("PASS", "steps-invoke-named-empty-frame", "steps(invoke-outer-config-named-empty-frame)", "result Config: (fib-store ; empty-frame) ; CTORCONSTA2(CTORI32A0, 5)"),
    ("KNOWN_STUCK", "steps-fib-config-invoke", "steps(fib-config-invoke(i32v(5)))", "result StepsConf: steps($invoke"),
    ("PASS", "expanddt-fib", "$expanddt(value('TYPE, fib-funcinst))", "result V128: CTORFUNCARROWA2"),
    ("PASS", "label-br-suffix-search", "CTORLABELLBRACERBRACEA3(0,", "Solution 1"),
    ("PASS", "br-if-suffix-search", "CTORBRIFA1(0) CTORLOCALGETA1(1)", "Solution 1"),
    ("PASS", "nop-suffix-search", "CTORNOPA0 CTORLOCALGETA1(0)", "Solution 1"),
    ("PASS", "steps-fib-config", "steps(fib-config(i32v(5)))", "result Config: (fib-store ; empty-frame) ; CTORCONSTA2(CTORI32A0, 5)"),
]


def normalize(s: str) -> str:
    return re.sub(r"\s+", " ", s.strip())


def split_blocks(text: str) -> list[str]:
    chunks = [c.strip() for c in text.split("==========================================")]
    return [c for c in chunks if c]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: summarize_c1_probe_results.py <c1_probe_suite.log>", file=sys.stderr)
        return 2

    log_path = Path(sys.argv[1])
    text = log_path.read_text()
    blocks = [(b, normalize(b)) for b in split_blocks(text)]

    rows: list[tuple[str, str, str, str]] = []
    failed = False

    for expectation, name, command_hint, expected_hint in PROBES:
        command_hint_n = normalize(command_hint)
        expected_hint_n = normalize(expected_hint)
        matches = [b for b, bn in blocks if command_hint_n in bn]
        if not matches:
            rows.append((expectation, name, "MISSING", f"command hint not found: {command_hint}"))
            failed = True
            continue
        block_n = normalize(matches[0])
        ok = expected_hint_n in block_n
        if ok:
            rows.append((expectation, name, "OK", expected_hint))
        else:
            rows.append((expectation, name, "UNEXPECTED", f"expected hint not found: {expected_hint}"))
            failed = True

    print("| expectation | probe | status | evidence |")
    print("|---|---|---|---|")
    for expectation, name, status, evidence in rows:
        print(f"| {expectation} | {name} | {status} | `{evidence}` |")

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
