#!/usr/bin/env python3
"""Run source-valid probes for Phase 1 dangerous rule-audit statuses.

The broad concrete rule audit is intentionally mechanical and sometimes builds
source-invalid `search =>+ exact rhs` probes.  This focused script keeps a small
catalog of source-valid commands for the rules that previously showed
STACK_OVERFLOW / MAUDE_EXIT_2 / TIMEOUT so we can distinguish translator bugs
from audit-sample bugs.
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from audit_output_bs_rules_concrete import ROOT, SAMPLE_MODULE, maude_bin


@dataclass(frozen=True)
class Probe:
    name: str
    command: str
    expect: str
    evidence: str


RT_I31 = "CTORREFA2(eps, CTORI31A0)"
RT_FUNC = "CTORREFA2(eps, CTORFUNCA0)"
STRUCT_DT = "CTORWDEFA2(CTORRECA1(CTORSUBA3(eps, eps, CTORSTRUCTA1(CTORMUTA0 CTORI32A0))), 0)"
Z_STRUCT = (
    "(fib-store ; "
    f"RECFrameA2(eps, RECModuleinstA9({STRUCT_DT}, eps, eps, eps, eps, eps, eps, eps, eps)))"
)
Z_EXN = (
    "(RECStoreA10(eps, eps, eps, eps, eps, eps, eps, eps, eps, "
    "RECExninstA2(0, I32VAL0)) ; "
    "RECFrameA2(eps, RECModuleinstA9(eps, 0, eps, eps, eps, eps, eps, eps, eps)))"
)


PROBES = [
    Probe(
        "clos-empty",
        "red in C1-RULE-CONCRETE-SAMPLES : $clos-deftypes(eps) .",
        "PASS",
        "result Nonfuncs: eps",
    ),
    Probe(
        "clos-one-fib-type",
        "red in C1-RULE-CONCRETE-SAMPLES : $clos-deftypes(fib-type) .",
        "PASS",
        "result",
    ),
    Probe(
        "clos-two-fib-type",
        "red in C1-RULE-CONCRETE-SAMPLES : $clos-deftypes(fib-type fib-type) .",
        "PASS",
        "result",
    ),
    Probe(
        "alloctypes-empty",
        "red in C1-RULE-CONCRETE-SAMPLES : $alloctypes(eps) .",
        "PASS",
        "result Nonfuncs: eps",
    ),
    Probe(
        "alloctypes-one-fib-source-type",
        "red in C1-RULE-CONCRETE-SAMPLES : $alloctypes(fib-source-type) .",
        "PASS",
        "result",
    ),
    Probe(
        "evalexprss-empty",
        "red in C1-RULE-CONCRETE-SAMPLES : $evalexprss(ST0, eps) .",
        "PASS",
        "result State: fib-store ; empty-frame",
    ),
    Probe(
        "evalexprss-one-const-flat",
        "red in C1-RULE-CONCRETE-SAMPLES : $evalexprss(ST0, INSTR1) .",
        "KNOWN_LIMITATION",
        "result V128: $evalexprss",
    ),
    Probe(
        "array-fill-succ-source-valid",
        "rew [1] in C1-RULE-CONCRETE-SAMPLES : step-read(ST0 ; CTORREFARRAYADDRA1(0) CTORCONSTA2(CTORI32A0, 0) CTORCONSTA2(CTORI32A0, 1) CTORCONSTA2(CTORI32A0, 1) CTORARRAYFILLA1(0)) .",
        "PASS",
        "result Nonfuncs:",
    ),
    Probe(
        "elem-refs-projection",
        "red in C1-RULE-CONCRETE-SAMPLES : value('REFS, $elem(Z-ELEM0, 0)) .",
        "PASS",
        "result Addrref: CTORREFI31NUMA1(7)",
    ),
    Probe(
        "array-new-elem-alloc-source-valid",
        "rew [20] in C1-RULE-CONCRETE-SAMPLES : step-read(Z-ELEM0 ; CTORCONSTA2(CTORI32A0, 0) CTORCONSTA2(CTORI32A0, 1) CTORARRAYNEWELEMA2(0, 0)) .",
        "PASS",
        "result Nonfuncs: CTORREFI31NUMA1(7) CTORARRAYNEWFIXEDA2(0, 1)",
    ),
    Probe(
        "infer-fieldtype-ok-arg1-c0",
        "rew [50] in C1-RULE-CONCRETE-SAMPLES : $infer-fieldtype-ok-arg1(C0) .",
        "PASS",
        "result Nonfuncs: CTORMUTA0 CTORBOTA0",
    ),
    Probe(
        "expr-ok-const-source-valid",
        "rew [100] in C1-RULE-CONCRETE-SAMPLES : Expr-ok-const(C0, INSTR1, CTORI32A0) .",
        "PASS",
        "result ValidJudgement: valid",
    ),
    Probe(
        "step-pure-br-label-zero-source-valid",
        "rew [10] in C1-RULE-CONCRETE-SAMPLES : step-pure(CTORLABELLBRACERBRACEA3(1, eps, I32VAL0 CTORBRA1(0))) .",
        "PASS",
        "CTORCONSTA2(CTORI32A0, 0)",
    ),
    Probe(
        "step-pure-br-label-succ-source-valid",
        "rew [10] in C1-RULE-CONCRETE-SAMPLES : step-pure(CTORLABELLBRACERBRACEA3(0, eps, I32VAL0 CTORBRA1(1))) .",
        "PASS",
        "CTORCONSTA2(CTORI32A0, 0) CTORBRA1(0)",
    ),
    Probe(
        "step-pure-br-handler-source-valid",
        "rew [10] in C1-RULE-CONCRETE-SAMPLES : step-pure(CTORHANDLERLBRACERBRACEA3(0, eps, I32VAL0 CTORBRA1(1))) .",
        "PASS",
        "CTORCONSTA2(CTORI32A0, 0) CTORBRA1(1)",
    ),
    Probe(
        "step-pure-return-label-source-valid",
        "rew [10] in C1-RULE-CONCRETE-SAMPLES : step-pure(CTORLABELLBRACERBRACEA3(0, eps, I32VAL0 CTORRETURNA0)) .",
        "PASS",
        "CTORCONSTA2(CTORI32A0, 0) CTORRETURNA0",
    ),
    Probe(
        "step-pure-return-handler-source-valid",
        "rew [10] in C1-RULE-CONCRETE-SAMPLES : step-pure(CTORHANDLERLBRACERBRACEA3(0, eps, I32VAL0 CTORRETURNA0)) .",
        "PASS",
        "CTORCONSTA2(CTORI32A0, 0) CTORRETURNA0",
    ),
    Probe(
        "step-read-br-on-cast-succeed-source-valid",
        f"rew [30] in C1-RULE-CONCRETE-SAMPLES : step-read(ST0 ; CTORREFI31NUMA1(7) CTORBRONCASTA3(1, {RT_I31}, {RT_I31})) .",
        "PASS",
        "CTORREFI31NUMA1(7) CTORBRA1(1)",
    ),
    Probe(
        "step-read-br-on-cast-fail-fail-source-valid",
        f"rew [30] in C1-RULE-CONCRETE-SAMPLES : step-read(ST0 ; CTORREFI31NUMA1(7) CTORBRONCASTFAILA3(1, {RT_I31}, {RT_FUNC})) .",
        "KNOWN_LIMITATION",
        "Fatal error: stack overflow",
    ),
    Probe(
        "step-read-return-call-ref-label-source-valid",
        "rew [20] in C1-RULE-CONCRETE-SAMPLES : step-read(ST0 ; CTORLABELLBRACERBRACEA3(0, eps, I32VAL0 CTORRETURNCALLREFA1(TYPEUSE0))) .",
        "PASS",
        "CTORCONSTA2(CTORI32A0, 0) CTORRETURNCALLREFA1(CTORWIDXA1(0))",
    ),
    Probe(
        "step-read-return-call-ref-handler-source-valid",
        "rew [20] in C1-RULE-CONCRETE-SAMPLES : step-read(ST0 ; CTORHANDLERLBRACERBRACEA3(0, eps, I32VAL0 CTORRETURNCALLREFA1(TYPEUSE0))) .",
        "PASS",
        "CTORCONSTA2(CTORI32A0, 0) CTORRETURNCALLREFA1(CTORWIDXA1(0))",
    ),
    Probe(
        "step-read-throw-ref-handler-catch-source-valid",
        f"rew [30] in C1-RULE-CONCRETE-SAMPLES : step-read({Z_EXN} ; CTORHANDLERLBRACERBRACEA3(0, CTORCATCHA2(0, 1), CTORREFEXNADDRA1(0) CTORTHROWREFA0)) .",
        "PASS",
        "CTORCONSTA2(CTORI32A0, 0) CTORBRA1(1)",
    ),
    Probe(
        "step-read-struct-new-default-source-valid",
        f"rew [30] in C1-RULE-CONCRETE-SAMPLES : step-read({Z_STRUCT} ; CTORSTRUCTNEWDEFAULTA1(0)) .",
        "PASS",
        "CTORCONSTA2(CTORI32A0, 0) CTORSTRUCTNEWA1(0)",
    ),
    Probe(
        "infer-instrs-ok-arg0-r3-source-valid",
        "rew [100] in C1-RULE-CONCRETE-SAMPLES : $infer-instrs-ok-arg0(eps, CTORARROWA3(CTORI32A0, eps, CTORI32A0)) .",
        "KNOWN_LIMITATION",
        "result V128: $infer-instrs-ok-arg0",
    ),
]


def classify(output: str, probe: Probe) -> str:
    if probe.expect == "KNOWN_LIMITATION":
        if probe.evidence in output:
            return "EXPECTED_LIMITATION"
        if "Fatal error: stack overflow" in output:
            return "EXPECTED_STACK_OVERFLOW"
        return "UNEXPECTED"
    if probe.evidence in output and "Fatal error: stack overflow" not in output and "Maude internal error" not in output:
        return "PASS"
    if "Fatal error: stack overflow" in output:
        return "STACK_OVERFLOW"
    if "Maude internal error" in output:
        return "MAUDE_INTERNAL_ERROR"
    if "No solution" in output:
        return "NO_SOLUTION"
    return "UNEXPECTED"


def main() -> int:
    out_dir = ROOT / "artifacts" / f"phase1-error-triage-{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    out_dir.mkdir(parents=True, exist_ok=True)
    rows = []
    for probe in PROBES:
        text = SAMPLE_MODULE + "\n" + probe.command + "\nq\n"
        try:
            proc = subprocess.run(
                [maude_bin(), "-no-banner"],
                cwd=ROOT,
                input=text,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=30,
            )
            stdout = proc.stdout
        except subprocess.TimeoutExpired as exc:
            partial = exc.stdout or ""
            if isinstance(partial, bytes):
                partial = partial.decode(errors="replace")
            stdout = partial + "\n[TIMEOUT]\n"
        log_path = out_dir / f"{probe.name}.log"
        log_path.write_text(stdout)
        status = classify(stdout, probe)
        if "[TIMEOUT]" in stdout:
            status = "EXPECTED_TIMEOUT" if probe.expect == "KNOWN_LIMITATION" else "TIMEOUT"
        rows.append((probe, status, log_path))
        print(f"{probe.name}: {status}", flush=True)

    summary = out_dir / "summary.md"
    with summary.open("w") as f:
        f.write("# Phase 1 priority source-valid probe results\n\n")
        for probe, status, log_path in rows:
            f.write(
                f"- `{probe.name}`: {status} "
                f"(`{log_path.relative_to(ROOT)}`)\n"
            )
    print(f"[DONE] {out_dir.relative_to(ROOT)}")
    return 0 if all(status in {"PASS", "EXPECTED_LIMITATION", "EXPECTED_STACK_OVERFLOW", "EXPECTED_TIMEOUT"} for _, status, _ in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
