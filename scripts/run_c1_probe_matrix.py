#!/usr/bin/env python3
"""Run C1 concrete probes one-by-one.

Unlike a single Maude input file, this runner isolates every probe in its own
Maude process.  That matters because a stack overflow in one validation query
otherwise aborts the rest of the audit.
"""

from __future__ import annotations

import csv
import os
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MAUDE = Path("/Users/minsung/Dev/tools/Maude-3.5.1-macos-x86_64/maude")


COMMON_MODULE = r"""
load wasm-exec-bs

mod C1-PROBE-TERMS is
  inc WASM-FIB-BS .

  op C0 : -> Context .
  eq C0 =
    {item('TYPES, eps) ; item('RECS, eps) ; item('TAGS, eps) ;
     item('GLOBALS, eps) ; item('MEMS, eps) ; item('TABLES, eps) ;
     item('FUNCS, eps) ; item('DATAS, eps) ; item('ELEMS, eps) ;
     item('LOCALS, eps) ; item('LABELS, eps) ; item('RETURN, eps) ;
     item('REFS, eps)} .

  op invoke-literal-moduleinst : -> Moduleinst .
  eq invoke-literal-moduleinst =
    {item('TYPES, eps) ; item('TAGS, eps) ; item('GLOBALS, eps) ;
     item('MEMS, eps) ; item('TABLES, eps) ; item('FUNCS, eps) ;
     item('DATAS, eps) ; item('ELEMS, eps) ; item('EXPORTS, eps)} .

  op invoke-outer-frame : -> Frame .
  eq invoke-outer-frame = RECFrameA2(eps, invoke-literal-moduleinst) .

  op invoke-inner-frame : -> Frame .
  eq invoke-inner-frame =
    RECFrameA2(i32v(5) i32v(0) i32v(1) i32v(0), fib-moduleinst) .

  op invoke-inner-instrs : -> SpectecTerminals .
  eq invoke-inner-instrs =
    CTORLABELLBRACERBRACEA3(1, eps, fib-body) .

  op invoke-outer-config : -> Config .
  eq invoke-outer-config =
    (fib-store ; invoke-outer-frame) ;
      CTORFRAMELBRACERBRACEA3(1, invoke-inner-frame, invoke-inner-instrs) .

  op invoke-outer-config-named-empty-frame : -> Config .
  eq invoke-outer-config-named-empty-frame =
    (fib-store ; empty-frame) ;
      CTORFRAMELBRACERBRACEA3(1, invoke-inner-frame, invoke-inner-instrs) .
endm
"""


@dataclass(frozen=True)
class Probe:
    name: str
    expectation: str
    command: str
    expected_hint: str
    limitation: str = ""


PROBES: list[Probe] = [
    Probe("index-empty", "PASS", "red in C1-PROBE-TERMS : index(CTORI32A0 CTORI64A0, eps) .", "result Nonfuncs: eps"),
    Probe("index-sequence", "PASS", "red in C1-PROBE-TERMS : index(CTORI32A0 CTORI64A0, 0 1) .", "result Nonfuncs: CTORI32A0 CTORI64A0"),
    Probe("index-locals-empty", "PASS", "red in C1-PROBE-TERMS : index(value('LOCALS, C0), eps) .", "result Nonfuncs: eps"),
    Probe("resulttype-ok-empty", "PASS", "rew [100] in C1-PROBE-TERMS : Resulttype-ok(C0, eps) .", "result ValidJudgement: valid"),
    Probe("resulttype-ok-multi", "PASS", "rew [100] in C1-PROBE-TERMS : Resulttype-ok(C0, CTORI32A0 CTORI32A0) .", "result ValidJudgement: valid"),
    Probe("resulttype-sub-empty", "PASS", "rew [100] in C1-PROBE-TERMS : Resulttype-sub(C0, eps, eps) .", "result ValidJudgement: valid"),
    Probe("instrtype-ok-empty-arrow", "PASS", "rew [100] in C1-PROBE-TERMS : Instrtype-ok(C0, CTORARROWA3(eps, eps, eps)) .", "result ValidJudgement: valid"),
    Probe("instrtype-sub-empty-arrow", "PASS", "rew [100] in C1-PROBE-TERMS : Instrtype-sub(C0, CTORARROWA3(eps, eps, eps), CTORARROWA3(eps, eps, eps)) .", "result ValidJudgement: valid"),
    Probe("instrtype-ok-i32-arrow", "PASS", "rew [100] in C1-PROBE-TERMS : Instrtype-ok(C0, CTORARROWA3(CTORI32A0, eps, CTORI32A0)) .", "result ValidJudgement: valid"),
    Probe("instrtype-sub-i32-arrow", "PASS", "rew [100] in C1-PROBE-TERMS : Instrtype-sub(C0, CTORARROWA3(CTORI32A0, eps, CTORI32A0), CTORARROWA3(CTORI32A0, eps, CTORI32A0)) .", "result ValidJudgement: valid"),
    Probe("instr-ok-nop", "PASS", "rew [100] in C1-PROBE-TERMS : Instr-ok(C0, CTORNOPA0, CTORARROWA3(eps, eps, eps)) .", "result ValidJudgement: valid"),
    Probe("instr-ok-unreachable", "PASS", "rew [100] in C1-PROBE-TERMS : Instr-ok(C0, CTORUNREACHABLEA0, CTORARROWA3(eps, eps, eps)) .", "result ValidJudgement: valid"),
    Probe("externaddr-ok-fib", "PASS", "rew [100] in C1-PROBE-TERMS : Externaddr-ok(fib-store, CTORFUNCA1(0), CTORFUNCA1(fib-type)) .", "result ValidJudgement: valid"),
    Probe("instrs-ok-nop", "PASS", "rew [1000] in C1-PROBE-TERMS : Instrs-ok(C0, CTORNOPA0, CTORARROWA3(eps, eps, eps)) .", "result ValidJudgement: valid"),
    Probe("expr-ok-nop", "PASS", "rew [100] in C1-PROBE-TERMS : Expr-ok(C0, CTORNOPA0, eps) .", "result ValidJudgement: valid"),
    Probe(
        "instrs-ok-const-i32",
        "KNOWN_LIMITATION",
        "rew [100] in C1-PROBE-TERMS : Instrs-ok(C0, CTORCONSTA2(CTORI32A0, 0), CTORARROWA3(eps, eps, CTORI32A0)) .",
        "result ValidJudgement: valid",
        "현재 Instrs-ok/sub 실행 overlay가 non-empty value-producing sequence에서 재귀적으로 다시 같은 Instrs-ok를 시도해 stack overflow가 난다.",
    ),
    Probe(
        "expr-ok-const",
        "KNOWN_LIMITATION",
        "rew [100] in C1-PROBE-TERMS : Expr-ok-const(C0, CTORCONSTA2(CTORI32A0, 0), CTORI32A0) .",
        "result ValidJudgement: valid",
        "Expr-ok-const는 내부적으로 Expr-ok -> Instrs-ok(CONST ...)를 타므로 같은 Instrs-ok/sub recursion limitation에 걸린다.",
    ),
    Probe(
        "global-ok-const",
        "KNOWN_LIMITATION",
        "rew [100] in C1-PROBE-TERMS : Global-ok(C0, CTORGLOBALA2(CTORMUTA0 CTORI32A0, CTORCONSTA2(CTORI32A0, 0)), CTORMUTA0 CTORI32A0) .",
        "result ValidJudgement: valid",
        "Global-ok는 Expr-ok/Expr-ok-const에 의존하므로 같은 limitation에 걸린다.",
    ),
    Probe("val-ok-empty-sequence", "KNOWN_LIMITATION", "rew [100] in C1-PROBE-TERMS : Val-ok(fib-store, eps, eps) .", "result ValidJudgement: valid", "SpecTec source는 singleton Val-ok이고 sequence list-lift footer는 C1에서 제거했다."),
    Probe("val-ok-multi-sequence", "KNOWN_LIMITATION", "rew [100] in C1-PROBE-TERMS : Val-ok(fib-store, CTORCONSTA2(CTORI32A0, 5) CTORCONSTA2(CTORI32A0, 0), CTORI32A0 CTORI32A0) .", "result ValidJudgement: valid", "SpecTec source는 singleton Val-ok이고 sequence list-lift footer는 C1에서 제거했다."),
    Probe("invoke-rewrites-to-config", "PASS", "rew [100] in C1-PROBE-TERMS : $invoke(fib-store, 0, i32v(5) i32v(0) i32v(1)) .", "result Config:"),
    Probe("steps-invoke-outer-config", "KNOWN_LIMITATION", "rew [1000] in C1-PROBE-TERMS : steps(invoke-outer-config) .", "result Config: (fib-store ; invoke-outer-frame) ; CTORCONSTA2", "source-shaped outer frame context does not currently compose through Step/ctxt-frame execution path."),
    Probe("steps-invoke-named-empty-frame", "PASS", "rew [1000] in C1-PROBE-TERMS : steps(invoke-outer-config-named-empty-frame) .", "result Config: (fib-store ; empty-frame) ; CTORCONSTA2(CTORI32A0, 5)"),
    Probe("steps-fib-config-invoke", "KNOWN_LIMITATION", "rew [10000] in C1-PROBE-TERMS : steps(fib-config-invoke(i32v(5))) .", "result Config: (fib-store ; empty-frame) ; CTORCONSTA2(CTORI32A0, 5)", "fib-config-invoke uses the source-shaped invoke/outer-frame path and gets stuck at the same Step/ctxt-frame limitation."),
    Probe("expanddt-fib", "PASS", "red in C1-PROBE-TERMS : $expanddt(value('TYPE, fib-funcinst)) .", "result V128: CTORFUNCARROWA2"),
    Probe("label-br-suffix-search", "PASS", "search [5] in C1-PROBE-TERMS : step((fib-store ; RECFrameA2(CTORCONSTA2(CTORI32A0, 0) CTORCONSTA2(CTORI32A0, 5) CTORCONSTA2(CTORI32A0, 8) CTORCONSTA2(CTORI32A0, 8), fib-moduleinst)) ; CTORLABELLBRACERBRACEA3(0, eps, CTORBRA1(0)) CTORLOCALGETA1(1)) =>* C:Config .", "Solution 1"),
    Probe("br-if-suffix-search", "PASS", "search [5] in C1-PROBE-TERMS : step(((fib-store ; empty-frame).State ; CTORCONSTA2(CTORI32A0, 1) CTORBRIFA1(0) CTORLOCALGETA1(1))) =>* C:Config .", "Solution 1"),
    Probe("nop-suffix-search", "PASS", "search [5] in C1-PROBE-TERMS : step(((fib-store ; empty-frame).State ; CTORNOPA0 CTORLOCALGETA1(0))) =>* C:Config .", "Solution 1"),
    Probe("steps-fib-config", "PASS", "rew [10000] in C1-PROBE-TERMS : steps(fib-config(i32v(5))) .", "result Config: (fib-store ; empty-frame) ; CTORCONSTA2(CTORI32A0, 5)"),
]


def maude_bin() -> str:
    env = os.environ.get("MAUDE_BIN")
    if env:
        return env
    if DEFAULT_MAUDE.exists():
        return str(DEFAULT_MAUDE)
    return "maude"


def classify_output(probe: Probe, text: str, returncode: int, timed_out: bool) -> tuple[str, str]:
    if timed_out:
        if probe.expectation == "KNOWN_LIMITATION":
            return ("EXPECTED_TIMEOUT", f"timeout; {probe.limitation}")
        return ("TIMEOUT", f"timeout; expected={probe.expectation}; {probe.limitation}")
    if "Fatal error: stack overflow" in text:
        status = "EXPECTED_STACK_OVERFLOW" if probe.expectation == "KNOWN_LIMITATION" else "STACK_OVERFLOW"
        return (status, probe.limitation or "stack overflow")
    if probe.expected_hint in text:
        if probe.expectation == "PASS":
            return ("PASS", probe.expected_hint)
        return ("UNEXPECTED_PASS", "known limitation unexpectedly passed")
    if probe.expectation == "KNOWN_LIMITATION":
        return ("EXPECTED_STUCK", probe.limitation or "did not reach expected valid result")
    if returncode != 0:
        return ("MAUDE_ERROR", f"returncode={returncode}")
    return ("FAIL", f"missing expected hint: {probe.expected_hint}")


def main() -> int:
    timeout = int(os.environ.get("C1_PROBE_TIMEOUT", "8"))
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_dir = ROOT / "artifacts" / f"c1-probe-matrix-{stamp}"
    out_dir.mkdir(parents=True, exist_ok=True)

    rows: list[dict[str, str]] = []
    failed = False
    for idx, probe in enumerate(PROBES, 1):
        probe_file = out_dir / f"{idx:03d}-{probe.name}.maude"
        log_file = out_dir / f"{idx:03d}-{probe.name}.log"
        probe_file.write_text(f"{COMMON_MODULE}\n{probe.command}\nq\n")
        timed_out = False
        try:
            proc = subprocess.run(
                [maude_bin(), "-no-banner"],
                cwd=ROOT,
                input=probe_file.read_text(),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=timeout,
            )
            text = proc.stdout
            returncode = proc.returncode
        except subprocess.TimeoutExpired as exc:
            timed_out = True
            text = (exc.stdout or "") if isinstance(exc.stdout, str) else ""
            returncode = 124
        log_file.write_text(text)
        status, evidence = classify_output(probe, text, returncode, timed_out)
        if status in {"FAIL", "STACK_OVERFLOW", "TIMEOUT", "MAUDE_ERROR"}:
            failed = True
        rows.append(
            {
                "probe": probe.name,
                "expectation": probe.expectation,
                "status": status,
                "evidence": evidence,
                "command": probe.command,
                "log": str(log_file.relative_to(ROOT)),
            }
        )
        print(f"[{idx:03d}/{len(PROBES):03d}] {probe.name}: {status}")

    csv_path = out_dir / "probe_results.csv"
    with csv_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["probe", "expectation", "status", "evidence", "command", "log"])
        writer.writeheader()
        writer.writerows(rows)

    md_path = out_dir / "probe_summary.md"
    with md_path.open("w") as f:
        f.write("# C1 Probe Matrix Summary\n\n")
        f.write("| probe | expectation | status | evidence |\n")
        f.write("|---|---|---|---|\n")
        for row in rows:
            evidence = row["evidence"].replace("|", "\\|")
            f.write(f"| {row['probe']} | {row['expectation']} | {row['status']} | `{evidence}` |\n")

    print(f"[DONE] {out_dir.relative_to(ROOT)}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
