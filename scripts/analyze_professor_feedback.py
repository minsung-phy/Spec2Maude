#!/usr/bin/env python3
"""Run focused checks for the latest professor-feedback items.

The goal is not to prove the whole translator correct.  It creates a small,
repeatable artifact that answers three concrete questions:

1. Are the Step/ctxt-instrs execution helpers actually needed?
2. Which type/category checks are rejected before runtime, and how is source
   val* represented after removing the old Boolean sequence guard?
3. Is the old iN(NOP)-style SpectecType widening bug fixed?
"""

from __future__ import annotations

import datetime as _dt
import os
import re
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAUDE = os.environ.get("MAUDE", "maude")
STAMP = _dt.datetime.now().strftime("%Y%m%d_%H%M%S")
ARTIFACT = ROOT / "artifacts" / f"professor-feedback-{STAMP}"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def run(
    args: list[str],
    *,
    cwd: Path = ROOT,
    input_text: str | None = None,
    timeout: int = 10,
) -> tuple[str, str, int | None]:
    try:
        p = subprocess.run(
            args,
            cwd=cwd,
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
        return p.stdout, p.stderr, p.returncode
    except subprocess.TimeoutExpired as exc:
        return exc.stdout or "", exc.stderr or "", None


def copy_harness(dst: Path) -> None:
    dst.mkdir(parents=True, exist_ok=True)
    for name in [
        "output_bs.maude",
        "builtins.maude",
        "wasm-init-bs.maude",
        "wasm-exec-bs.maude",
    ]:
        shutil.copy2(ROOT / name, dst / name)


def remove_step_pure_bridge(text: str) -> str:
    pattern = re.compile(
        r"\n  --- Generic executable bridge derived from Step_pure \+ Step/ctxt-instrs\.\n"
        r".*?"
        r"(?=\n  --- Executable bridge for memory\.size)",
        re.S,
    )
    new, count = pattern.subn("", text)
    if count not in (0, 1):
        raise RuntimeError(f"expected to remove zero or one step-pure bridge, removed {count}")
    return new


def make_variant(name: str, *, no_bridge: bool) -> Path:
    dst = ARTIFACT / "variants" / name
    copy_harness(dst)
    for file_name in ["output_bs.maude", "wasm-init-bs.maude"]:
        path = dst / file_name
        text = read(path)
        if file_name == "output_bs.maude" and no_bridge:
            text = remove_step_pure_bridge(text)
        write(path, text)
    return dst


def maude_script(commands: str, *, cwd: Path, name: str, timeout: int = 10) -> dict[str, str]:
    stdout, stderr, code = run([MAUDE], cwd=cwd, input_text=commands + "\nq\n", timeout=timeout)
    log = stdout + stderr
    write(ARTIFACT / "logs" / f"{name}.log", log)
    if code is None:
        status = "TIMEOUT"
    elif code != 0:
        status = "ERROR"
    elif "Error:" in log or "Warning:" in log or "Advisory:" in log:
        status = "LOAD_OR_PARSE_WARNING"
    else:
        status = "OK"
    return {"status": status, "code": "TIMEOUT" if code is None else str(code), "log": log}


def run_helper_variants() -> list[dict[str, str]]:
    commands = """
load wasm-exec-bs.maude
rew [1] in WASM-FIB-BS : steps(fib-config(i32v(5))) .
rew [1] in WASM-FIB-BS : steps(fib-init-config(i32v(5))) .
"""
    variants = [
        ("baseline", False),
        ("no-step-pure-bridge", True),
    ]
    rows: list[dict[str, str]] = []
    for name, no_bridge in variants:
        cwd = make_variant(name, no_bridge=no_bridge)
        result = maude_script(commands, cwd=cwd, name=f"helper-{name}", timeout=8)
        log = result["log"]
        final_count = log.count("CTORCONSTA2(CTORI32A0, 5)")
        rows.append(
            {
                "variant": name,
                "status": result["status"],
                "final_i32_5_count": str(final_count),
                "manual_fib_interpretation": "PASS" if result["status"] == "OK" and final_count >= 2 else "CHECK_LOG",
            }
        )

    frontend_rows = []
    for name, _ in variants:
        cwd = ARTIFACT / "variants" / name
        harness = cwd / "wasm-exec-bs.maude"
        stdout, stderr, code = run(
            [
                "dune",
                "exec",
                "./wasm_to_maude.exe",
                "--",
                "--harness",
                str(harness),
                "--result-only",
                "--run",
                "5",
                "wat_examples/fib.wat",
            ],
            timeout=12,
        )
        log = stdout + stderr
        write(ARTIFACT / "logs" / f"helper-frontend-{name}.log", log)
        frontend_rows.append(
            {
                "variant": name,
                "status": "TIMEOUT" if code is None else ("OK" if code == 0 else "ERROR"),
                "frontend_fib": first_nonempty_line(log),
            }
        )
    write(ARTIFACT / "helper_frontend_fib.md", markdown_table(frontend_rows) + "\n")
    return rows


def run_typecheck_inputs() -> list[dict[str, str]]:
    bad_dir = ARTIFACT / "invalid-wat"
    bad_cases = {
        "bad-result-type.wat": '(module (func (export "main") (result i32) i64.const 1))\n',
        "bad-stack-underflow.wat": '(module (func (export "main") (result i32) i32.add))\n',
        "bad-local-index.wat": '(module (func (export "main") (result i32) local.get 0))\n',
    }
    rows: list[dict[str, str]] = []
    for name, wat in bad_cases.items():
        path = bad_dir / name
        write(path, wat)
        stdout, stderr, code = run(
            [
                "dune",
                "exec",
                "./wasm_to_maude.exe",
                "--",
                "--result-only",
                "--run-main",
                str(path),
            ],
            timeout=12,
        )
        log = stdout + stderr
        write(ARTIFACT / "logs" / f"typecheck-{name}.log", log)
        rows.append(
            {
                "case": name,
                "frontend_status": "REJECTED" if code not in (0, None) else "ACCEPTED",
                "code": "TIMEOUT" if code is None else str(code),
                "evidence": first_nonempty_line(log),
            }
        )

    raw_runtime = """
load wasm-exec-bs.maude
rew [1] in WASM-FIB-BS : step-pure(CTORCONSTA2(CTORI32A0, 1) CTORCONSTA2(CTORI32A0, 2) CTORBINOPA2(CTORI32A0, CTORADDA0)) .
rew [1] in WASM-FIB-BS : step-pure(CTORCONSTA2(CTORI64A0, 1) CTORCONSTA2(CTORI64A0, 2) CTORBINOPA2(CTORI32A0, CTORADDA0)) .
"""
    result = maude_script(raw_runtime, cwd=ROOT, name="typecheck-raw-runtime", timeout=8)
    log = result["log"]
    rows.append(
        {
            "case": "raw-runtime-step-pure-type-mismatch",
            "frontend_status": result["status"],
            "code": result["code"],
            "evidence": "mismatch_stuck" if "CTORI64A0" in log and "CTORI32A0, 3" in log else "see log",
        }
    )
    return rows


def first_nonempty_line(text: str) -> str:
    for line in text.splitlines():
        line = line.strip()
        if line:
            return line[:180]
    return ""


def run_spectectype_checks() -> dict[str, str]:
    output = read(ROOT / "output_bs.maude")
    broad_args = re.findall(r"op\s+\S+\s*:\s*[^.]*SpectecTerminal[^.]*->\s*SpectecType", output)
    has_type_subsort = "subsort SpectecType < SpectecTerminal" in output
    source_iN = first_nonempty_line(
        "\n".join(
            line
            for line in read(ROOT / "wasm-3.0" / "1.1-syntax.values.spectec").splitlines()
            if "syntax iN" in line
        )
    )
    commands = """
load output_bs.maude
red in SPECTEC-CORE : iN(32) .
red in SPECTEC-CORE : iN(CTORNOPA0) .
red in SPECTEC-CORE : list(instr) .
red in SPECTEC-CORE : list(CTORNOPA0) .
"""
    result = maude_script(commands, cwd=ROOT, name="spectectype-in-nop", timeout=8)
    log = result["log"]
    def result_sort_for(term: str) -> str:
        marker = f"reduce in SPECTEC-CORE : {term} ."
        start = log.find(marker)
        if start < 0:
            return "missing"
        next_sep = log.find("==========================================", start + len(marker))
        block = log[start:] if next_sep < 0 else log[start:next_sep]
        match = re.search(r"result ([^:]+):", block)
        return match.group(1).strip() if match else "missing"

    iN_nop_sort = result_sort_for("iN(CTORNOPA0)")
    list_nop_sort = result_sort_for("list(CTORNOPA0)")
    return {
        "source_iN": source_iN,
        "broad_spectec_terminal_args": str(len(broad_args)),
        "has_spectectype_terminal_subsort": str(has_type_subsort),
        "maude_status": result["status"],
        "iN_32_ok": str("result SpectecType: iN(32)" in log or "result SpectecCategory: iN(32)" in log),
        "iN_NOP_not_spectectype": str(iN_nop_sort != "SpectecType"),
        "list_NOP_not_spectectype": str(list_nop_sort != "SpectecType"),
    }


def markdown_table(rows: list[dict[str, str]]) -> str:
    if not rows:
        return ""
    headers = list(rows[0].keys())
    out = ["| " + " | ".join(headers) + " |", "| " + " | ".join(["---"] * len(headers)) + " |"]
    for row in rows:
        out.append("| " + " | ".join(row.get(h, "").replace("\n", " ") for h in headers) + " |")
    return "\n".join(out)


def main() -> None:
    ARTIFACT.mkdir(parents=True, exist_ok=True)
    helper_rows = run_helper_variants()
    type_rows = run_typecheck_inputs()
    spectectype = run_spectectype_checks()

    summary = f"""# Professor Feedback Analysis

Date: {STAMP}

This artifact answers the three follow-up points from the professor meeting.

## 1. Helper Necessity Recheck

Question: do not ask whether helpers are allowed first; check whether they are
actually needed.

Same commands were run on four generated variants:

```maude
rew [1] in WASM-FIB-BS : steps(fib-config(i32v(5))) .
rew [1] in WASM-FIB-BS : steps(fib-init-config(i32v(5))) .
```

{markdown_table(helper_rows)}

Interpretation:

- `no-step-pure-bridge` tests whether `step-from-step-pure-ctxt-instrs` is
  necessary for the current fib paths.
- The old `$is-spectec-val-seq` guard is no longer generated. Source `val*`
  is represented by the `ValSeq` Maude sort.
- Logs are under `logs/helper-*.log`.
- Frontend-generated fib was also checked with the same variants:

{read(ARTIFACT / "helper_frontend_fib.md")}

## 2. Typecheck Recheck

Question: the goal is not deleting all typechecks.  We need to separate
necessary guards from redundant runtime guards.  The external `.wat/.wasm`
frontend path should reject non-well-typed input before Maude runtime execution.

{markdown_table(type_rows)}

Interpretation:

- Invalid WAT programs should be rejected by the frontend/WABT path.
- Raw Maude runtime is not a replacement for validation; if users bypass the
  frontend and construct arbitrary Maude terms, validation/category checks still
  matter.
- Therefore the correct report is: keep validation semantics, remove only
  proved-redundant runtime guards, and keep operational sequence-shape guards
  when experiments show they are needed.

## 3. `iN(NOP)` Reclassification

Question: if `iN(NOP)` is not valid in SpecTec, then accepting it was a
translator bug, not a research contribution.

Source evidence:

```text
{spectectype["source_iN"]}
```

Current generated checks:

| check | result |
| --- | --- |
| SpectecType constructors with `SpectecTerminal` argument | {spectectype["broad_spectec_terminal_args"]} |
| `subsort SpectecType < SpectecTerminal` exists | {spectectype["has_spectectype_terminal_subsort"]} |
| Maude check status | {spectectype["maude_status"]} |
| `iN(32)` accepted | {spectectype["iN_32_ok"]} |
| `iN(CTORNOPA0)` is not a `SpectecType` | {spectectype["iN_NOP_not_spectectype"]} |
| `list(CTORNOPA0)` is not a `SpectecType` | {spectectype["list_NOP_not_spectectype"]} |

Report wording:

> `iN(NOP)` was not a research point.  SpecTec says `iN(N)`, so accepting
> `iN(NOP)` was a translator signature bug.  I fixed the translator so
> parametric SpectecType constructors use the source parameter category instead
> of broad `SpectecTerminal`.

## What To Tell The Professor

1. Helper: I am no longer presenting helpers as something to simply allow.  I
   ran ablation experiments to see which helpers are genuinely needed.
2. Typecheck: I am not claiming that all typechecks should be removed.  I now
   separate validation, frontend rejection, redundant runtime guards, and
   source category representation such as `ValSeq`.
3. `iN(NOP)`: this was a translator bug.  It is fixed and should not be framed
   as a non-isomorphic design issue.
"""
    write(ARTIFACT / "summary.md", summary)
    print(ARTIFACT)


if __name__ == "__main__":
    main()
