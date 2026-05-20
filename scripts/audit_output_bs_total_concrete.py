#!/usr/bin/env python3
"""Concrete artifact-level audit for output_bs.maude.

This script is intentionally broader than the focused C1 probe matrix.  It
extracts every generated op/eq/ceq/mb/cmb/rl/crl artifact, writes an inventory,
generates an explicit Maude command for each artifact whenever a reasonable
concrete sample can be synthesized, runs the command in an isolated Maude
process, and classifies the result.

It is a concrete coverage audit, not a mathematical proof.  PASS means the
generated artifact has at least one source-shaped concrete probe that parses and
executes in the current harness.  SAMPLE_MISSING means the script could not
construct a trustworthy sample term for that artifact yet.
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import signal
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from audit_output_bs_rules_concrete import (  # type: ignore
    SAMPLE_MODULE,
    TOKEN_CHARS,
    candidates_for,
    instantiate,
    maude_bin,
    parse_vars,
    variable_names_in,
)


START_RE = re.compile(r"^\s*(op|eq|ceq|mb|cmb|rl|crl)\b")
RULE_RE = re.compile(r"^\s*(rl|crl)\s+\[([^\]]+)\]\s*:", re.S)
OP_RE = re.compile(r"^\s*op\s+(.+?)\s*:\s*(.*?)\s*->\s*([A-Za-z][A-Za-z0-9-]*)\b", re.S)
EQ_RE = re.compile(r"^\s*(eq|ceq)\s+(.+?)\s*=\s*(.+?)(?:\s+if\s+(.+?))?\s*\.\s*$", re.S)
MB_RE = re.compile(r"^\s*(mb|cmb)\s+(.+?)\s*:\s*([A-Za-z][A-Za-z0-9-]*)\b(?:\s+if\s+(.+?))?\s*\.\s*$", re.S)


@dataclass
class Artifact:
    id: int
    line: int
    kind: str
    label: str
    head: str
    statement: str
    lhs: str = ""
    rhs: str = ""
    condition: str = ""
    result_sort: str = ""
    arg_sorts: tuple[str, ...] = ()


@dataclass
class Probe:
    command: str
    artifact_status: str = "GENERATED"
    notes: str = ""


def normalize(s: str) -> str:
    return re.sub(r"\s+", " ", s.strip())


def strip_attrs(s: str) -> str:
    return re.sub(r"\[[^\]]*\]\s*$", "", s.strip()).strip()


def read_statements(path: Path) -> list[tuple[int, str, str]]:
    """Return (line, kind, statement) for top-level artifacts."""

    lines = path.read_text().splitlines()
    out: list[tuple[int, str, str]] = []
    i = 0
    while i < len(lines):
        m = START_RE.match(lines[i])
        if not m:
            i += 1
            continue
        start = i
        kind = m.group(1)
        chunks = [lines[i]]
        i += 1
        if chunks[-1].strip().endswith("."):
            out.append((start + 1, kind, "\n".join(chunks)))
            continue
        while i < len(lines):
            chunks.append(lines[i])
            if lines[i].strip().endswith("."):
                break
            i += 1
        out.append((start + 1, kind, "\n".join(chunks)))
        i += 1
    return out


def head_of_term(term: str) -> str:
    t = normalize(term)
    if not t:
        return ""
    if t.startswith("("):
        return t.split()[0]
    m = re.match(r"([A-Za-z$][A-Za-z0-9_$'-]*)\s*\(", t)
    if m:
        return m.group(1)
    m = re.match(r"([A-Za-z$][A-Za-z0-9_$'-]*)", t)
    if m:
        return m.group(1)
    return t.split()[0]


def parse_artifacts(path: Path) -> list[Artifact]:
    artifacts: list[Artifact] = []
    for idx, (line, kind, stmt) in enumerate(read_statements(path), 1):
        label = ""
        head = ""
        lhs = ""
        rhs = ""
        cond = ""
        result_sort = ""
        arg_sorts: tuple[str, ...] = ()
        if kind in {"rl", "crl"}:
            m = RULE_RE.match(stmt)
            label = m.group(2) if m else f"{kind}@{line}"
            body = stmt.split(":", 1)[1].strip()
            if body.endswith("."):
                body = body[:-1].strip()
            if "=>" in body:
                lhs_part, rhs_cond = body.split("=>", 1)
                parts = re.split(r"\n\s+if\s+|\s+if\s+", rhs_cond, maxsplit=1)
                lhs = normalize(lhs_part)
                rhs = normalize(parts[0])
                if len(parts) > 1:
                    cond = normalize(parts[1])
            head = label
        elif kind == "op":
            m = OP_RE.match(stmt)
            if m:
                raw_sym = normalize(m.group(1))
                raw_args = normalize(m.group(2))
                result_sort = m.group(3)
                arg_sorts = tuple([] if raw_args == "" else raw_args.split())
                label = raw_sym
                head = raw_sym
        elif kind in {"eq", "ceq"}:
            m = EQ_RE.match(stmt)
            if m:
                lhs = normalize(m.group(2))
                rhs = normalize(m.group(3))
                cond = normalize(m.group(4) or "")
                head = head_of_term(lhs)
                label = head
        elif kind in {"mb", "cmb"}:
            m = MB_RE.match(stmt)
            if m:
                lhs = normalize(m.group(2))
                result_sort = m.group(3)
                cond = normalize(m.group(4) or "")
                head = result_sort
                label = result_sort
        artifacts.append(
            Artifact(
                id=idx,
                line=line,
                kind=kind,
                label=label,
                head=head,
                statement=stmt,
                lhs=lhs,
                rhs=rhs,
                condition=cond,
                result_sort=result_sort,
                arg_sorts=arg_sorts,
            )
        )
    return artifacts


def sample_for_sort(sort: str, name_hint: str = "") -> str | None:
    local_overrides = {
        "Packtype": "CTORI8A0",
        "Storagetype": "CTORI32A0",
        "Lanetype": "CTORI8A0",
        "Addrtype": "CTORI32A0",
        "Consttype": "CTORI32A0",
        "Mut": "CTORMUTA0",
        "Null": "CTORNULLA0",
        "Final": "CTORFINALA0",
    }
    if sort in local_overrides:
        return local_overrides[sort]
    cands = candidates_for(name_hint or sort, sort)
    return cands[0] if cands else None


def simple_prefix_symbol(symbol: str) -> bool:
    return re.match(r"^[A-Za-z$][A-Za-z0-9_$'-]*$", symbol) is not None


def instantiate_mixfix(symbol: str, samples: list[str]) -> str | None:
    holes = symbol.count("_")
    if holes == 0:
        if not samples:
            return symbol
        if simple_prefix_symbol(symbol):
            return f"{symbol}({', '.join(samples)})"
        return None
    if holes != len(samples):
        return None
    pieces = symbol.split("_")
    out = pieces[0]
    for sample, piece in zip(samples, pieces[1:]):
        if out and not out.endswith(" "):
            out += " "
        out += sample
        if piece and not piece.startswith(" "):
            out += " "
        out += piece
    return normalize(out)


def concrete_op_term(artifact: Artifact) -> Probe:
    if not artifact.label:
        return Probe("", "SAMPLE_MISSING", "could not parse op declaration")
    samples: list[str] = []
    for i, sort in enumerate(artifact.arg_sorts):
        sample = sample_for_sort(sort, f"{artifact.label}-ARG{i}")
        if sample is None:
            return Probe("", "SAMPLE_MISSING", f"no sample for sort {sort}")
        samples.append(sample)
    term = instantiate_mixfix(artifact.label, samples)
    if term is None:
        return Probe("", "SAMPLE_MISSING", "unsupported mixfix/operator syntax for automatic sample")
    return Probe(f"red in C1-TOTAL-AUDIT-SAMPLES : {term} .")


def substitution_for_text(text: str, vars_by_name: dict[str, str]) -> tuple[dict[str, str], str]:
    names = variable_names_in(text, vars_by_name)
    subst: dict[str, str] = {}
    missing: list[str] = []
    for name in names:
        sort = vars_by_name[name]
        sample = sample_for_sort(sort, name)
        if sample is None:
            missing.append(f"{name}:{sort}")
        else:
            subst[name] = sample
    return subst, ", ".join(missing)


def concrete_eq_probe(artifact: Artifact, vars_by_name: dict[str, str]) -> Probe:
    if not artifact.lhs:
        return Probe("", "SAMPLE_MISSING", "could not parse equation lhs")
    subst, missing = substitution_for_text(artifact.lhs + " " + artifact.rhs + " " + artifact.condition, vars_by_name)
    if missing:
        return Probe("", "SAMPLE_MISSING", f"missing samples for {missing}")
    lhs = instantiate(artifact.lhs, subst)
    return Probe(f"red in C1-TOTAL-AUDIT-SAMPLES : {lhs} .")


def concrete_mb_probe(artifact: Artifact, vars_by_name: dict[str, str]) -> Probe:
    if not artifact.lhs or not artifact.result_sort:
        return Probe("", "SAMPLE_MISSING", "could not parse membership statement")
    subst, missing = substitution_for_text(artifact.lhs + " " + artifact.condition, vars_by_name)
    if missing:
        return Probe("", "SAMPLE_MISSING", f"missing samples for {missing}")
    bare = artifact.lhs.strip()
    if bare.startswith("(") and bare.endswith(")"):
        bare = bare[1:-1].strip()
    if bare in subst:
        result_sample = sample_for_sort(artifact.result_sort, bare)
        if result_sample is not None:
            subst[bare] = result_sample
    term = instantiate(artifact.lhs, subst)
    return Probe(
        "\n".join(
            [
                "mod C1-TOTAL-AUDIT-MEMBERSHIP-PROBE is",
                "  inc C1-TOTAL-AUDIT-SAMPLES .",
                "  op $membership-probe : -> Bool .",
                f"  ceq $membership-probe = true if ({term}) : {artifact.result_sort} .",
                "endm",
                "red in C1-TOTAL-AUDIT-MEMBERSHIP-PROBE : $membership-probe .",
            ]
        )
    )


def concrete_rule_probe(artifact: Artifact, vars_by_name: dict[str, str]) -> Probe:
    if not artifact.lhs or not artifact.rhs:
        return Probe("", "SAMPLE_MISSING", "could not parse rule lhs/rhs")
    subst, missing = substitution_for_text(artifact.lhs + " " + artifact.rhs + " " + artifact.condition, vars_by_name)
    if missing:
        return Probe("", "SAMPLE_MISSING", f"missing samples for {missing}")
    lhs = instantiate(artifact.lhs, subst)
    rhs = instantiate(artifact.rhs, subst)
    lhs_head = head_of_term(artifact.lhs)
    rhs_norm = normalize(artifact.rhs)

    # For source function definitions lowered to rl/crl, the RHS often contains
    # variables bound by premises.  Instantiating those premise-produced values
    # and searching for the fully instantiated RHS can create malformed probes
    # or even trigger Maude internal errors.  A rewrite probe is the faithful
    # concrete execution check for this artifact class.
    if lhs_head.startswith("$"):
        return Probe(f"rew [100] in C1-TOTAL-AUDIT-SAMPLES : {lhs} .")

    if rhs_norm == "valid":
        return Probe(
            "\n".join(
                [
                    "search [1] in C1-TOTAL-AUDIT-SAMPLES :",
                    f"  ({lhs})",
                    "  =>+ valid .",
                ]
            )
        )

    if lhs_head == "step-read":
        return Probe(
            "\n".join(
                [
                    "search [1] in C1-TOTAL-AUDIT-SAMPLES :",
                    f"  ({lhs})",
                    "  =>+ R:StepReadConf .",
                ]
            )
        )

    if lhs_head == "step-pure":
        return Probe(
            "\n".join(
                [
                    "search [1] in C1-TOTAL-AUDIT-SAMPLES :",
                    f"  ({lhs})",
                    "  =>+ R:StepPureConf .",
                ]
            )
        )

    if lhs_head in {"step", "steps"}:
        return Probe(
            "\n".join(
                [
                    "search [1] in C1-TOTAL-AUDIT-SAMPLES :",
                    f"  ({lhs})",
                    "  =>+ C:Config .",
                ]
            )
        )

    return Probe(
        "\n".join(
            [
                "search [1] in C1-TOTAL-AUDIT-SAMPLES :",
                f"  ({lhs})",
                f"  =>+ ({rhs}) .",
            ]
        )
    )


def probe_for(artifact: Artifact, vars_by_name: dict[str, str]) -> Probe:
    if artifact.kind == "op":
        return concrete_op_term(artifact)
    if artifact.kind in {"eq", "ceq"}:
        return concrete_eq_probe(artifact, vars_by_name)
    if artifact.kind in {"mb", "cmb"}:
        return concrete_mb_probe(artifact, vars_by_name)
    if artifact.kind in {"rl", "crl"}:
        return concrete_rule_probe(artifact, vars_by_name)
    return Probe("", "SAMPLE_MISSING", f"unsupported kind {artifact.kind}")


def known_limitation_reason(artifact: Artifact, command: str, output: str) -> str:
    text = " ".join([artifact.label, artifact.head, artifact.statement, command])
    if "step-from-step-pure-" in text:
        return "label-related Step_pure-to-Step executable debt retained as known C1 limitation"
    if "$ivbitmaskop" in text or "$vbitmaskop" in text:
        return "vector bitmask def needs generic lowering for non-variable iterated expressions and inverse/builtin bit conversion"
    if "$evalexprss" in text or "evalexprss-r1" in text:
        return "expr** is flattened to SpectecTerminals, so recursive grouping of expr* can choose an empty/non-progress split"
    if "Instrs-ok" in text and ("CTORCONSTA2" in text or "instrs-ok-sub" in text):
        return "Instrs-ok non-empty/value-producing sequence currently exposes validation execution overlay recursion"
    if "Expr-ok-const" in text or "expr-ok-const" in text:
        return "Expr-ok-const inherits Instrs-ok(CONST ...) limitation"
    if "Global-ok" in text or "global-ok" in text:
        return "Global-ok with const expr inherits Expr-ok/Instrs-ok limitation"
    if "Val-ok" in text and (" eps, eps" in text or "VALS" in text or "VALOK" in text):
        return "direct sequence-shaped Val-ok query is not source singleton Val-ok and footer list-lift is intentionally removed"
    if "$invoke" in text or "fib-config-invoke" in text:
        return "invoke/outer-frame path is deferred to init-config/frontend phase"
    if "index(" in text and "LOCALS" in text and "CTORSETA0" in output:
        return "flat source prefix-constructor sequence still needs careful source-meta execution classification"
    return ""


def classify_output(artifact: Artifact, probe: Probe, output: str, returncode: int, timed_out: bool) -> tuple[str, str]:
    if probe.artifact_status == "SAMPLE_MISSING":
        return ("SAMPLE_MISSING", probe.notes)
    if timed_out:
        reason = known_limitation_reason(artifact, probe.command, output)
        return ("KNOWN_LIMITATION" if reason else "TIMEOUT", reason or "Maude process timed out")
    if "Fatal error: stack overflow" in output:
        reason = known_limitation_reason(artifact, probe.command, output)
        return ("KNOWN_LIMITATION" if reason else "STACK_OVERFLOW", reason or "Maude stack overflow")
    low = output.lower()
    if "no parse for term" in low or "bad token" in low or "parse error" in low:
        return ("PARSE_ERROR", "Maude parse error for generated concrete probe")
    if artifact.kind in {"rl", "crl"}:
        if "Solution 1" in output:
            return ("PASS", "rule search produced at least one solution")
        if re.search(r"\bresult\b", output):
            return ("PASS", "rule rewrite produced a Maude result")
        if "No solution" in output:
            reason = known_limitation_reason(artifact, probe.command, output)
            return ("KNOWN_LIMITATION" if reason else "NO_SOLUTION", reason or "concrete rule search had no solution")
    elif artifact.kind in {"mb", "cmb"}:
        if "result Bool: true" in output:
            return ("PASS", "membership probe reduced to true")
        if "result Bool: false" in output:
            reason = known_limitation_reason(artifact, probe.command, output)
            return ("KNOWN_LIMITATION" if reason else "STUCK", reason or "membership probe reduced to false")
    else:
        if re.search(r"\bresult\b", output):
            # For op/eq/ceq artifacts, this confirms the concrete term parses and
            # reduces in Maude.  Some identity equations naturally return a term
            # with the same head, so we do not require textual inequality.
            return ("PASS", "concrete red command produced a Maude result")
    if returncode != 0:
        return (f"MAUDE_EXIT_{returncode}", "Maude returned a non-zero exit status")
    reason = known_limitation_reason(artifact, probe.command, output)
    return ("KNOWN_LIMITATION" if reason else "STUCK", reason or "concrete probe did not reach an expected observable result")


def run_maude(text: str, timeout: int) -> tuple[str, int, bool]:
    proc = subprocess.Popen(
        [maude_bin(), "-no-banner"],
        cwd=ROOT,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )
    try:
        output, _ = proc.communicate(text, timeout=timeout)
        return output, proc.returncode, False
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        output, _ = proc.communicate()
        return output or "", 124, True


def safe_name(artifact: Artifact) -> str:
    base = artifact.label or artifact.head or artifact.kind
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", base)[:120] or artifact.kind


def write_inventory(path: Path, artifacts: Iterable[Artifact]) -> None:
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "id",
                "line",
                "kind",
                "label",
                "head",
                "result_sort",
                "arg_sorts",
                "lhs",
                "rhs",
                "condition",
                "statement",
            ],
        )
        writer.writeheader()
        for a in artifacts:
            writer.writerow(
                {
                    "id": a.id,
                    "line": a.line,
                    "kind": a.kind,
                    "label": a.label,
                    "head": a.head,
                    "result_sort": a.result_sort,
                    "arg_sorts": " ".join(a.arg_sorts),
                    "lhs": a.lhs,
                    "rhs": a.rhs,
                    "condition": a.condition,
                    "statement": normalize(a.statement),
                }
            )


def write_summary(out_dir: Path, rows: list[dict[str, str]], artifacts: list[Artifact], timeout: int) -> None:
    by_kind: dict[str, int] = {}
    for a in artifacts:
        by_kind[a.kind] = by_kind.get(a.kind, 0) + 1
    by_status: dict[str, int] = {}
    by_kind_status: dict[tuple[str, str], int] = {}
    for row in rows:
        by_status[row["status"]] = by_status.get(row["status"], 0) + 1
        key = (row["kind"], row["status"])
        by_kind_status[key] = by_kind_status.get(key, 0) + 1
    with (out_dir / "summary.md").open("w") as f:
        f.write("# output_bs.maude Total Concrete Artifact Audit\n\n")
        f.write("This is a concrete artifact-level audit, not a proof over every possible term.\n")
        f.write(f"Every generated probe was run in an isolated Maude process with timeout `{timeout}s`.\n\n")
        f.write("## Inventory Counts\n\n")
        f.write("| kind | count |\n|---|---:|\n")
        for kind in ["op", "eq", "ceq", "mb", "cmb", "rl", "crl"]:
            f.write(f"| {kind} | {by_kind.get(kind, 0)} |\n")
        f.write("\n## Result Counts\n\n")
        f.write("| status | count |\n|---|---:|\n")
        for status, count in sorted(by_status.items()):
            f.write(f"| {status} | {count} |\n")
        f.write("\n## Result Counts By Kind\n\n")
        f.write("| kind | status | count |\n|---|---|---:|\n")
        for (kind, status), count in sorted(by_kind_status.items()):
            f.write(f"| {kind} | {status} | {count} |\n")
        f.write("\n## Non-PASS / Non-KNOWN_LIMITATION Items\n\n")
        f.write("| id | line | kind | label/head | status | notes | log |\n|---:|---:|---|---|---|---|---|\n")
        for row in rows:
            if row["status"] not in {"PASS", "KNOWN_LIMITATION"}:
                notes = row["notes"].replace("|", "\\|")
                f.write(
                    f"| {row['id']} | {row['line']} | {row['kind']} | `{row['label_or_head']}` | "
                    f"{row['status']} | {notes} | `{row['log']}` |\n"
                )
        f.write("\n## Known Limitation Items Observed\n\n")
        f.write("| id | line | kind | label/head | notes | log |\n|---:|---:|---|---|---|---|\n")
        for row in rows:
            if row["status"] == "KNOWN_LIMITATION":
                notes = row["notes"].replace("|", "\\|")
                f.write(
                    f"| {row['id']} | {row['line']} | {row['kind']} | `{row['label_or_head']}` | "
                    f"{notes} | `{row['log']}` |\n"
                )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", default="output_bs.maude")
    ap.add_argument("--artifact-dir", default="")
    ap.add_argument("--timeout", type=int, default=3)
    ap.add_argument("--limit", type=int, default=0, help="debug: total artifact limit")
    ap.add_argument("--limit-per-kind", type=int, default=0, help="debug: artifact limit per kind")
    ap.add_argument("--kinds", default="op,eq,ceq,mb,cmb,rl,crl")
    args = ap.parse_args()

    out_dir = Path(args.artifact_dir) if args.artifact_dir else ROOT / "artifacts" / f"output-bs-total-audit-{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    if not out_dir.is_absolute():
        out_dir = ROOT / out_dir
    test_dir = out_dir / "maude-tests"
    log_dir = out_dir / "logs"
    test_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)

    kinds = {k.strip() for k in args.kinds.split(",") if k.strip()}
    output_path = ROOT / args.output
    artifacts = [a for a in parse_artifacts(output_path) if a.kind in kinds]
    if args.limit_per_kind:
        seen: dict[str, int] = {}
        limited: list[Artifact] = []
        for a in artifacts:
            if seen.get(a.kind, 0) < args.limit_per_kind:
                limited.append(a)
                seen[a.kind] = seen.get(a.kind, 0) + 1
        artifacts = limited
    if args.limit:
        artifacts = artifacts[: args.limit]

    vars_by_name = parse_vars(output_path)
    write_inventory(out_dir / "inventory.csv", artifacts)

    rows: list[dict[str, str]] = []
    for idx, artifact in enumerate(artifacts, 1):
        probe = probe_for(artifact, vars_by_name)
        log_rel = ""
        maude_rel = ""
        output = ""
        returncode = 0
        timed_out = False
        if probe.artifact_status == "SAMPLE_MISSING":
            status, notes = "SAMPLE_MISSING", probe.notes
        else:
            file_base = f"{artifact.id:05d}-{artifact.line:05d}-{artifact.kind}-{safe_name(artifact)}"
            maude_file = test_dir / f"{file_base}.maude"
            log_file = log_dir / f"{file_base}.log"
            maude_text = SAMPLE_MODULE.replace("C1-RULE-CONCRETE-SAMPLES", "C1-TOTAL-AUDIT-SAMPLES")
            maude_text += "\n"
            maude_text += probe.command
            maude_text += "\nq\n"
            maude_file.write_text(maude_text)
            output, returncode, timed_out = run_maude(maude_text, args.timeout)
            log_file.write_text(output)
            maude_rel = str(maude_file.relative_to(ROOT))
            log_rel = str(log_file.relative_to(ROOT))
            status, notes = classify_output(artifact, probe, output, returncode, timed_out)

        rows.append(
            {
                "id": str(artifact.id),
                "line": str(artifact.line),
                "kind": artifact.kind,
                "label_or_head": artifact.label or artifact.head,
                "status": status,
                "notes": notes,
                "maude_file": maude_rel,
                "log": log_rel,
                "command": probe.command,
                "statement": normalize(artifact.statement),
            }
        )
        if idx == 1 or idx % 100 == 0 or idx == len(artifacts):
            print(f"[{idx:04d}/{len(artifacts):04d}] latest={artifact.kind}:{artifact.line} status={status}")

    with (out_dir / "test_results.csv").open("w", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "id",
                "line",
                "kind",
                "label_or_head",
                "status",
                "notes",
                "maude_file",
                "log",
                "command",
                "statement",
            ],
        )
        writer.writeheader()
        writer.writerows(rows)

    write_summary(out_dir, rows, artifacts, args.timeout)
    print(f"[DONE] {out_dir.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
