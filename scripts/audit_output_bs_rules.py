#!/usr/bin/env python3
"""Inventory and symbolically probe every rl/crl in output_bs.maude.

This is an applicability audit, not a proof that every concrete program state
terminates.  For each generated rl/crl it asks Maude whether the generated LHS
can rewrite to the generated RHS in at least one step:

  search [1] in SPECTEC-CORE : <lhs> =>+ <rhs> .

The result is useful for finding parse errors, obvious dead rules, stack
overflows, and rules that require concrete witnesses or harness state.
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import subprocess
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MAUDE = Path("/Users/minsung/Dev/tools/Maude-3.5.1-macos-x86_64/maude")


@dataclass
class Rule:
    line: int
    kind: str
    label: str
    statement: str
    lhs: str
    rhs: str
    family: str


def maude_bin() -> str:
    env = os.environ.get("MAUDE_BIN")
    if env:
        return env
    if DEFAULT_MAUDE.exists():
        return str(DEFAULT_MAUDE)
    return "maude"


def normalize(s: str) -> str:
    return re.sub(r"\s+", " ", s.strip())


def family_of(label: str) -> str:
    if label.startswith("step-from-step-pure-"):
        return "NON_C1_FINAL_STEP_PURE_LIFT"
    if label.startswith("$exec-") or "exec-tail-empty" in label:
        return "VALIDATION_EXECUTION_OVERLAY"
    if label.startswith("$iter-"):
        return "RELATION_STAR_META_LOWERING"
    if label.startswith("step"):
        return "EXECUTION_STEP"
    if label.startswith("eval-"):
        return "EVAL"
    if label.startswith(("numtype-", "vectype-", "heaptype-", "reftype-", "valtype-", "resulttype-", "instrtype-", "instr-ok-", "instrs-ok-", "expr-", "module-", "func-", "externaddr-", "ref-ok-", "global-", "type-", "types-", "export-", "import-", "start-", "table-", "mem-", "tag-", "data-", "elem-")):
        return "SOURCE_RELATION_RULE"
    return "SOURCE_OR_DEF_RULE"


def parse_rules(path: Path) -> list[Rule]:
    lines = path.read_text().splitlines()
    rules: list[Rule] = []
    i = 0
    start_re = re.compile(r"^\s*(rl|crl)\s+\[([^\]]+)\]\s*:")
    while i < len(lines):
        m = start_re.match(lines[i])
        if not m:
            i += 1
            continue
        start = i
        chunks = [lines[i]]
        i += 1
        while i < len(lines):
            chunks.append(lines[i])
            if lines[i].strip().endswith("."):
                break
            i += 1
        stmt = "\n".join(chunks)
        body = stmt.split(":", 1)[1].strip()
        if body.endswith("."):
            body = body[:-1].strip()
        if "=>" not in body:
            lhs, rhs = body, ""
        else:
            lhs, rhs_cond = body.split("=>", 1)
            parts = re.split(r"\n\s+if\s+|\s+if\s+", rhs_cond, maxsplit=1)
            rhs = parts[0]
        rules.append(
            Rule(
                line=start + 1,
                kind=m.group(1),
                label=m.group(2),
                statement=stmt,
                lhs=normalize(lhs),
                rhs=normalize(rhs),
                family=family_of(m.group(2)),
            )
        )
        i += 1
    return rules


def write_inventory(rules: list[Rule], path: Path) -> None:
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=["line", "kind", "label", "family", "lhs", "rhs"],
        )
        writer.writeheader()
        for rule in rules:
            writer.writerow(
                {
                    "line": rule.line,
                    "kind": rule.kind,
                    "label": rule.label,
                    "family": rule.family,
                    "lhs": rule.lhs,
                    "rhs": rule.rhs,
                }
            )


def probe_rule(rule: Rule, out_dir: Path, timeout: int, module: str) -> dict[str, str]:
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", rule.label)[:120]
    probe_file = out_dir / "rule-probes" / f"{rule.line:05d}-{safe}.maude"
    log_file = out_dir / "rule-logs" / f"{rule.line:05d}-{safe}.log"
    probe_file.parent.mkdir(parents=True, exist_ok=True)
    log_file.parent.mkdir(parents=True, exist_ok=True)
    text = (
        "load output_bs.maude\n"
        f"search [1] in {module} :\n"
        f"  {rule.lhs}\n"
        f"  =>+ {rule.rhs} .\n"
        "q\n"
    )
    probe_file.write_text(text)
    timed_out = False
    try:
        proc = subprocess.run(
            [maude_bin(), "-no-banner"],
            cwd=ROOT,
            input=text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )
        output = proc.stdout
        returncode = proc.returncode
    except subprocess.TimeoutExpired as exc:
        timed_out = True
        output = (exc.stdout or "") if isinstance(exc.stdout, str) else ""
        returncode = 124
    log_file.write_text(output)
    if timed_out:
        status = "TIMEOUT"
    elif "Fatal error: stack overflow" in output:
        status = "STACK_OVERFLOW"
    elif "Solution 1" in output:
        status = "SOLUTION"
    elif "No solution" in output:
        status = "NO_SOLUTION"
    elif "Warning:" in output and "parse error" in output.lower():
        status = "PARSE_ERROR"
    elif returncode != 0:
        status = f"MAUDE_EXIT_{returncode}"
    else:
        status = "UNKNOWN"
    return {
        "line": str(rule.line),
        "kind": rule.kind,
        "label": rule.label,
        "family": rule.family,
        "status": status,
        "log": str(log_file.relative_to(ROOT)),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", default="output_bs.maude")
    ap.add_argument("--artifact-dir", default="")
    ap.add_argument("--run", action="store_true", help="run symbolic search for every selected rule")
    ap.add_argument("--timeout", type=int, default=5)
    ap.add_argument("--module", default="SPECTEC-CORE")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--label-regex", default="")
    args = ap.parse_args()

    out_dir = Path(args.artifact_dir) if args.artifact_dir else ROOT / "artifacts" / f"rule-audit-{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    if not out_dir.is_absolute():
        out_dir = ROOT / out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    rules = parse_rules(ROOT / args.output)
    if args.label_regex:
        rx = re.compile(args.label_regex)
        rules = [r for r in rules if rx.search(r.label)]
    if args.limit:
        rules = rules[: args.limit]

    write_inventory(rules, out_dir / "rule_inventory.csv")
    counts: dict[str, int] = {}
    for rule in rules:
        counts[rule.family] = counts.get(rule.family, 0) + 1

    rows: list[dict[str, str]] = []
    if args.run:
        for idx, rule in enumerate(rules, 1):
            row = probe_rule(rule, out_dir, args.timeout, args.module)
            rows.append(row)
            print(f"[{idx:04d}/{len(rules):04d}] {rule.label}: {row['status']}")
        with (out_dir / "rule_symbolic_results.csv").open("w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=["line", "kind", "label", "family", "status", "log"])
            writer.writeheader()
            writer.writerows(rows)

    with (out_dir / "summary.md").open("w") as f:
        f.write("# output_bs.maude rl/crl audit\n\n")
        f.write(f"- rules inventoried: {len(rules)}\n")
        f.write(f"- symbolic run: {'yes' if args.run else 'no'}\n\n")
        f.write("## Families\n\n")
        f.write("| family | count |\n|---|---:|\n")
        for family, count in sorted(counts.items()):
            f.write(f"| {family} | {count} |\n")
        if rows:
            status_counts: dict[str, int] = {}
            for row in rows:
                status_counts[row["status"]] = status_counts.get(row["status"], 0) + 1
            f.write("\n## Symbolic Status\n\n")
            f.write("| status | count |\n|---|---:|\n")
            for status, count in sorted(status_counts.items()):
                f.write(f"| {status} | {count} |\n")
            f.write("\n`NO_SOLUTION`, `TIMEOUT`, and `STACK_OVERFLOW` are audit leads, not automatically missing translations.\n")

    print(f"[DONE] {out_dir.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
