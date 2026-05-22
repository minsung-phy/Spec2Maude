#!/usr/bin/env python3
"""Concrete-sample probe every rl/crl in output_bs.maude.

This complements audit_output_bs_rules.py.  The symbolic audit asks Maude to
find witnesses for open terms.  This script instead substitutes generated
variables with small, concrete sample terms based on their declared sort/name,
then asks whether the instantiated LHS rewrites to the instantiated RHS.

It is still an audit, not a proof over all possible inputs.  A failed concrete
sample means "the generated sample did not exercise this rule"; a stack
overflow or Maude error is a stronger lead.
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

TOKEN_CHARS = r"A-Za-z0-9_$'\-*"


SAMPLE_MODULE = r"""
load wasm-exec-bs

mod C1-RULE-CONCRETE-SAMPLES is
  inc WASM-FIB-BS .

  op C0 : -> Context .
  eq C0 =
    {item('TYPES, eps) ; item('RECS, eps) ; item('TAGS, eps) ;
     item('GLOBALS, eps) ; item('MEMS, eps) ; item('TABLES, eps) ;
     item('FUNCS, eps) ; item('DATAS, eps) ; item('ELEMS, eps) ;
     item('LOCALS, eps) ; item('LABELS, eps) ; item('RETURN, eps) ;
     item('REFS, eps)} .

  op C1 : -> Context .
  eq C1 =
    {item('TYPES, eps) ; item('RECS, eps) ; item('TAGS, eps) ;
     item('GLOBALS, eps) ; item('MEMS, eps) ; item('TABLES, eps) ;
     item('FUNCS, eps) ; item('DATAS, eps) ; item('ELEMS, eps) ;
     item('LOCALS, CTORI32A0) ; item('LABELS, eps) ; item('RETURN, eps) ;
     item('REFS, eps)} .

  op C2 : -> Context .

  op ST0 : -> State .
  eq ST0 = fib-store ; empty-frame .

  op S-ELEM0 : -> Store .
  eq S-ELEM0 =
    RECStoreA10(eps, eps, eps, eps, eps, eps,
      RECEleminstA2(REF0, CTORREFI31NUMA1(7)),
      eps, eps, eps) .

  op MI-ELEM0 : -> Moduleinst .
  eq MI-ELEM0 =
    RECModuleinstA9(eps, eps, eps, eps, eps, eps, eps, 0, eps) .

  op Z-ELEM0 : -> State .
  eq Z-ELEM0 = S-ELEM0 ; RECFrameA2(eps, MI-ELEM0) .

  op CFG0 : -> Config .
  eq CFG0 = ST0 ; CTORNOPA0 .

  op FR0 : -> Frame .
  eq FR0 = empty-frame .

  op MI0 : -> Moduleinst .
  eq MI0 = fib-moduleinst .

  op MOD0 : -> Module .
  eq MOD0 = fib-module .

  op I32VAL0 : -> Val .
  eq I32VAL0 = CTORCONSTA2(CTORI32A0, 0) .

  op I32VAL1 : -> Val .
  eq I32VAL1 = CTORCONSTA2(CTORI32A0, 1) .

  op INSTR0 : -> Instr .
  eq INSTR0 = CTORNOPA0 .

  op INSTR1 : -> Instr .
  eq INSTR1 = CTORCONSTA2(CTORI32A0, 0) .

  op EXPR0 : -> Expr .
  eq EXPR0 = CTORNOPA0 .

  op ARROW0 : -> Instrtype .
  eq ARROW0 = CTORARROWA3(eps, eps, eps) .

  op ARROW1 : -> Instrtype .
  eq ARROW1 = CTORARROWA3(eps, eps, CTORI32A0) .

  op REF0 : -> Reftype .
  eq REF0 = CTORREFA2(eps, CTORI31A0) .

  op BLOCKTYPE0 : -> Blocktype .
  eq BLOCKTYPE0 = CTORWRESULTA1(eps) .

  op TYPEUSE0 : -> Typeuse .
  eq TYPEUSE0 = CTORWIDXA1(0) .

  op LIMITS0 : -> Limits .
  eq LIMITS0 = CTORLBRACKDOTDOTRBRACKA2(0, eps) .

  op MEMARG0 : -> Memarg .
  eq MEMARG0 = {item('ALIGN, 0) ; item('OFFSET, 0)} .

  eq C2 =
    RECContextA13(
      fib-type,                  --- TYPES
      eps,                       --- RECS
      TYPEUSE0,                  --- TAGS
      eps CTORI32A0,             --- GLOBALS
      CTORPAGEA2(CTORI32A0, LIMITS0), --- MEMS
      CTORI32A0 LIMITS0 REF0,    --- TABLES
      fib-type,                  --- FUNCS
      CTOROKA0,                  --- DATAS
      REF0,                      --- ELEMS
      CTORSETA0 CTORI32A0,       --- LOCALS
      CTORI32A0,                 --- LABELS
      CTORI32A0,                 --- RETURN
      0) .                       --- REFS
endm
"""


@dataclass
class Rule:
    line: int
    kind: str
    label: str
    statement: str
    lhs: str
    rhs: str
    vars: dict[str, str]


def maude_bin() -> str:
    env = os.environ.get("MAUDE_BIN")
    if env:
        return env
    if DEFAULT_MAUDE.exists():
        return str(DEFAULT_MAUDE)
    return "maude"


def normalize(s: str) -> str:
    return re.sub(r"\s+", " ", s.strip())


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
        lhs, rhs = body, ""
        if "=>" in body:
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
                vars={},
            )
        )
        i += 1
    return rules


def parse_vars(path: Path) -> dict[str, str]:
    text = path.read_text()
    vars_by_name: dict[str, str] = {}
    # Generated declarations are one-line var/vars statements.
    for m in re.finditer(r"^\s*vars?\s+(.+?)\s*:\s*([A-Za-z][A-Za-z0-9-]*)\s*\.\s*$", text, re.M):
        names, sort = m.group(1), m.group(2)
        for name in names.split():
            vars_by_name[name] = sort
    return vars_by_name


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
    if label.startswith(
        (
            "numtype-",
            "vectype-",
            "heaptype-",
            "reftype-",
            "valtype-",
            "resulttype-",
            "instrtype-",
            "instr-ok-",
            "instrs-ok-",
            "expr-",
            "module-",
            "func-",
            "externaddr-",
            "ref-ok-",
            "global-",
            "type-",
            "types-",
            "export-",
            "import-",
            "start-",
            "table-",
            "mem-",
            "tag-",
            "data-",
            "elem-",
        )
    ):
        return "SOURCE_RELATION_RULE"
    return "SOURCE_OR_DEF_RULE"


def name_hint(name: str) -> str:
    return name.upper().replace("-", "_")


def semantic_hint(name: str) -> str:
    """Return the source-ish suffix of a generated variable name.

    Generated variables include the whole rule label, e.g.
    INSTR-OK-BR-ON-NULL12-RT.  Looking at the full name makes every variable in
    an Instr-ok rule look instruction-like.  The right sampling cue is usually
    the final source binder fragment, such as RT, TS1, INSTRS, X, or BT.
    """

    pieces = [p for p in re.split(r"[-_]+", name.upper()) if p]
    if not pieces:
        return name_hint(name)
    tail = pieces[-1]
    tail = re.sub(r"^[0-9]+", "", tail)
    tail = re.sub(r"[0-9]+$", "", tail)
    if tail:
        return tail
    return pieces[-1]


def candidates_for(name: str, sort: str) -> list[str]:
    n = name_hint(name)
    h = semantic_hint(name)
    scalar_index = ["0", "1"]
    if "ARRAY-NEW-ELEM" in name.upper() and h == "N":
        return ["1", "0"]
    if sort in {"Nat", "Int", "N", "M", "K", "Idx", "Typeidx", "Funcidx", "Localidx", "Labelidx", "Globalidx", "Tableidx", "Memidx", "Tagidx", "Elemidx", "Dataidx", "Fieldidx", "Addr", "Funcaddr", "Externaddr", "Tableaddr", "Memaddr", "Globaladdr", "Tagaddr", "Elemaddr", "Dataaddr", "Arrayaddr", "Structaddr", "Exnaddr", "Hostaddr", "Laneidx", "U32", "U64", "U31"}:
        return scalar_index
    if sort == "Bool":
        return ["true", "false"]
    if sort == "Context":
        return ["C2", "C0", "C1"]
    if sort == "Store":
        return ["fib-store"]
    if sort == "Frame":
        return ["FR0", "RECFrameA2(eps, MI0)"]
    if sort == "State":
        if "ARRAY-NEW-ELEM" in name.upper():
            return ["Z-ELEM0", "ST0"]
        return ["ST0"]
    if sort == "Config":
        return ["CFG0"]
    if sort == "Moduleinst":
        return ["MI0"]
    if sort == "Module":
        return ["MOD0"]
    if sort == "Val":
        return ["I32VAL0", "I32VAL1"]
    if sort == "Instr":
        return ["INSTR0", "INSTR1"]
    if sort == "Expr":
        return ["EXPR0", "INSTR1"]
    if sort == "Numtype":
        return ["CTORI32A0", "CTORI64A0"]
    if sort == "Vectype":
        return ["CTORV128A0"]
    if sort == "Heaptype":
        return ["CTORI31A0", "CTORWEQA0"]
    if sort == "Reftype":
        return ["REF0"]
    if sort == "Valtype":
        return ["CTORI32A0", "REF0"]
    if sort == "Resulttype":
        return ["eps", "CTORI32A0"]
    if sort == "Instrtype":
        return ["ARROW0", "ARROW1"]
    if sort == "Blocktype":
        return ["BLOCKTYPE0"]
    if sort == "Typeuse":
        return ["TYPEUSE0"]
    if sort == "Limits":
        return ["LIMITS0"]
    if sort == "Memarg":
        return ["MEMARG0"]
    if sort == "Globaltype":
        return ["eps CTORI32A0", "CTORMUTA0 CTORI32A0"]
    if sort == "Tabletype":
        return ["CTORI32A0 LIMITS0 REF0"]
    if sort == "Memtype":
        return ["CTORPAGEA2(CTORI32A0, LIMITS0)"]
    if sort == "Externtype":
        return ["CTORFUNCA1(TYPEUSE0)", "CTORGLOBALA1(eps CTORI32A0)"]
    if sort == "Externidx":
        return ["CTORFUNCA1(0)", "CTORGLOBALA1(0)"]
    if sort == "Externaddr":
        return ["CTORFUNCA1(0)", "CTORGLOBALA1(0)"]

    if sort == "SpectecTerminals":
        if h in {"INSTRS", "INSTRSQ", "EXPR", "EXPRS", "CODE", "BODY"}:
            return ["INSTR0", "INSTR1", "eps"]
        if h in {"VAL", "VALS", "VALSQ", "V", "VS"}:
            return ["I32VAL0", "I32VAL0 I32VAL1", "eps"]
        if h in {"RT", "RTS", "REFTYPE", "REFTYPES"}:
            return ["REF0", "CTORREFA2(CTORNULLA0, CTORFUNCA0)", "eps"]
        if h in {"BT", "BLOCKTYPE"}:
            return ["BLOCKTYPE0", "eps"]
        if h in {"IT", "ITQ", "INSTRTYPE"}:
            return ["ARROW0", "ARROW1"]
        if h in {"DT", "DTS", "DEFTYPE", "DEFTYPES"}:
            return ["fib-type", "eps"]
        if h in {"TYPEUSE", "TYPEUSES", "TU", "TUS"}:
            return ["TYPEUSE0", "eps"]
        if h in {"GT", "GTS", "GLOBALTYPE", "GLOBALTYPES"}:
            return ["eps CTORI32A0", "CTORMUTA0 CTORI32A0", "eps"]
        if h in {"MT", "MTS", "MEMTYPE", "MEMTYPES"}:
            return ["CTORPAGEA2(CTORI32A0, LIMITS0)", "eps"]
        if h in {"TT", "TTS", "TABLETYPE", "TABLETYPES"}:
            return ["CTORI32A0 LIMITS0 REF0", "eps"]
        if h in {"ZT", "ZTS", "T", "TQ", "TS", "TSQ", "RESULT", "RESULTTYPE", "PARAMS"}:
            return ["eps", "CTORI32A0", "CTORI32A0 CTORI32A0"]
        if h in {"IDX", "IDXS", "XS", "X", "Y", "I", "J", "L", "IS", "LABEL", "LABELS", "LOCAL", "LOCALS", "REFS"}:
            return ["eps", "0", "0 1"]
        return ["eps", "CTORI32A0", "INSTR0"]

    if sort == "SpectecTerminal":
        if h in {"C", "CTX"} or n.endswith("_C") or n.endswith("-C"):
            return ["C2", "C0", "C1"]
        if h in {"INSTR", "INSTRQ", "INSTR1", "INSTR2", "EXPR", "CODE", "BODY"}:
            return ["INSTR0", "INSTR1", "CTORI32A0"]
        if h in {"VAL", "VALQ", "V", "VQ", "CONST"}:
            return ["I32VAL0", "CTORI32A0", "0"]
        if h in {"TYPEUSE", "TU", "YY"}:
            return ["TYPEUSE0", "CTORI32A0"]
        if h in {"RT", "RTQ", "REFTYPE"}:
            return ["REF0", "CTORI32A0"]
        if h in {"HT", "HTQ", "HEAPTYPE"}:
            return ["CTORI31A0", "CTORWEQA0"]
        if h in {"BT", "BLOCKTYPE"}:
            return ["BLOCKTYPE0", "CTORI32A0"]
        if h in {"IT", "ITQ", "INSTRTYPE"}:
            return ["ARROW0", "ARROW1"]
        if h in {"DT", "DTQ", "DTN", "DEFTYPE"}:
            return ["fib-type", "CTORI32A0"]
        if h == "TYPE" and "ALLOCTYPES" in name.upper():
            return ["fib-source-type", "CTORI32A0"]
        if h in {"GT", "GTQ", "GLOBALTYPE"}:
            return ["eps CTORI32A0", "CTORMUTA0 CTORI32A0"]
        if h in {"MT", "MTQ", "MEMTYPE"}:
            return ["CTORPAGEA2(CTORI32A0, LIMITS0)", "CTORI32A0"]
        if h in {"TT", "TTQ", "TABLETYPE"}:
            return ["CTORI32A0 LIMITS0 REF0", "CTORI32A0"]
        if h in {"LIM", "LIMITS"}:
            return ["LIMITS0", "eps"]
        if h in {"AT", "ADDRTYPE"}:
            return ["CTORI32A0", "CTORI64A0"]
        if h in {"NT", "NUMTYPE", "VT", "VALTYPE", "TYPE", "T", "TQ", "T1", "T2", "ZT"}:
            return ["CTORI32A0", "eps"]
        if h in {"IDX", "ADDR", "X", "Y", "I", "J", "L", "N", "M", "K", "A"}:
            return ["0", "1", "CTORI32A0"]
        return ["CTORI32A0", "0", "eps"]

    # For source categories not listed above, try common representatives.
    return ["CTORI32A0", "0", "eps"]


def variable_names_in(term: str, vars_by_name: dict[str, str]) -> list[str]:
    names = []
    for name in vars_by_name:
        pattern = rf"(?<![{TOKEN_CHARS}]){re.escape(name)}(?![{TOKEN_CHARS}])"
        if re.search(pattern, term):
            names.append(name)
    return sorted(names, key=len, reverse=True)


def instantiate(term: str, subst: dict[str, str]) -> str:
    out = term
    for name in sorted(subst, key=len, reverse=True):
        pattern = rf"(?<![{TOKEN_CHARS}]){re.escape(name)}(?![{TOKEN_CHARS}])"
        out = re.sub(pattern, subst[name], out)
    return out


def substitutions_for(rule: Rule, vars_by_name: dict[str, str], max_variants: int) -> list[dict[str, str]]:
    names = variable_names_in(rule.lhs + " " + rule.rhs, vars_by_name)
    if not names:
        return [{}]
    variants: list[dict[str, str]] = []
    for k in range(max_variants):
        subst: dict[str, str] = {}
        for name in names:
            cands = candidates_for(name, vars_by_name[name])
            subst[name] = cands[min(k, len(cands) - 1)]
        variants.append(subst)
    # A final "empty-ish" variant often helps source rules with star premises.
    emptyish: dict[str, str] = {}
    for name in names:
        sort = vars_by_name[name]
        if sort == "SpectecTerminals" or sort in {"Resulttype"}:
            emptyish[name] = "eps"
        else:
            emptyish[name] = candidates_for(name, sort)[0]
    variants.append(emptyish)
    # Deduplicate while preserving order.
    seen = set()
    uniq = []
    for subst in variants:
        key = tuple(sorted(subst.items()))
        if key not in seen:
            seen.add(key)
            uniq.append(subst)
    return uniq


def run_probe(rule: Rule, subst: dict[str, str], out_dir: Path, timeout: int, variant: int) -> tuple[str, str]:
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", rule.label)[:120]
    probe_dir = out_dir / "rule-probes"
    log_dir = out_dir / "rule-logs"
    probe_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)
    lhs = instantiate(rule.lhs, subst)
    rhs = instantiate(rule.rhs, subst)
    probe_file = probe_dir / f"{rule.line:05d}-{safe}-v{variant}.maude"
    log_file = log_dir / f"{rule.line:05d}-{safe}-v{variant}.log"
    text = (
        SAMPLE_MODULE
        + "\n"
        + "search [1] in C1-RULE-CONCRETE-SAMPLES :\n"
        + f"  ({lhs})\n"
        + f"  =>+ ({rhs}) .\n"
        + "q\n"
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
    elif "parse error" in output.lower() or "bad token" in output.lower():
        status = "PARSE_ERROR"
    elif returncode != 0:
        status = f"MAUDE_EXIT_{returncode}"
    else:
        status = "UNKNOWN"
    return status, str(log_file.relative_to(ROOT))


CSV_FIELDS = ["line", "kind", "label", "family", "status", "attempts", "log", "lhs", "rhs"]


def write_summary(path: Path, rows: list[dict[str, str]], *, completed: int, total: int, max_variants: int) -> None:
    counts: dict[str, int] = {}
    for row in rows:
        counts[row["status"]] = counts.get(row["status"], 0) + 1
    with path.open("w") as f:
        f.write("# output_bs.maude concrete-sample rl/crl audit\n\n")
        f.write(f"- rules completed: {completed} / {total}\n")
        f.write(f"- max variants per rule: {max_variants} + empty-ish variant\n\n")
        f.write("## Status counts\n\n")
        f.write("| status | count |\n|---|---:|\n")
        for status, count in sorted(counts.items()):
            f.write(f"| {status} | {count} |\n")
        f.write("\n## Non-solution statuses\n\n")
        f.write("| line | label | family | status | log |\n|---:|---|---|---|---|\n")
        for row in rows:
            if row["status"] != "SOLUTION":
                f.write(f"| {row['line']} | `{row['label']}` | {row['family']} | {row['status']} | `{row['log']}` |\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", default="output_bs.maude")
    ap.add_argument("--artifact-dir", default="")
    ap.add_argument("--timeout", type=int, default=4)
    ap.add_argument("--max-variants", type=int, default=3)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--label-regex", default="")
    args = ap.parse_args()

    out_dir = Path(args.artifact_dir) if args.artifact_dir else ROOT / "artifacts" / f"rule-concrete-audit-{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    if not out_dir.is_absolute():
        out_dir = ROOT / out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    output_path = ROOT / args.output
    vars_by_name = parse_vars(output_path)
    rules = parse_rules(output_path)
    if args.label_regex:
        rx = re.compile(args.label_regex)
        rules = [r for r in rules if rx.search(r.label)]
    if args.limit:
        rules = rules[: args.limit]

    rows: list[dict[str, str]] = []
    results_path = out_dir / "rule_concrete_results.csv"
    with results_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        writer.writeheader()
        f.flush()
        for idx, rule in enumerate(rules, 1):
            variants = substitutions_for(rule, vars_by_name, args.max_variants)
            best_status = "NO_ATTEMPT"
            best_log = ""
            attempted = 0
            stack_logs: list[str] = []
            parse_logs: list[str] = []
            for v_idx, subst in enumerate(variants):
                attempted += 1
                status, log = run_probe(rule, subst, out_dir, args.timeout, v_idx)
                if status == "SOLUTION":
                    best_status, best_log = status, log
                    break
                if status == "STACK_OVERFLOW":
                    stack_logs.append(log)
                if status == "PARSE_ERROR":
                    parse_logs.append(log)
                if best_status in {"NO_ATTEMPT", "NO_SOLUTION"}:
                    best_status, best_log = status, log
            if stack_logs and best_status != "SOLUTION":
                best_status, best_log = "STACK_OVERFLOW", stack_logs[0]
            elif parse_logs and best_status not in {"SOLUTION", "STACK_OVERFLOW"}:
                best_status, best_log = "PARSE_ERROR", parse_logs[0]
            row = {
                "line": str(rule.line),
                "kind": rule.kind,
                "label": rule.label,
                "family": family_of(rule.label),
                "status": best_status,
                "attempts": str(attempted),
                "log": best_log,
                "lhs": rule.lhs,
                "rhs": rule.rhs,
            }
            rows.append(row)
            writer.writerow(row)
            f.flush()
            print(f"[{idx:04d}/{len(rules):04d}] {rule.label}: {best_status} ({attempted} variants)", flush=True)
            if idx == 1 or idx % 25 == 0:
                write_summary(
                    out_dir / "summary.partial.md",
                    rows,
                    completed=idx,
                    total=len(rules),
                    max_variants=args.max_variants,
                )

    write_summary(
        out_dir / "summary.md",
        rows,
        completed=len(rows),
        total=len(rules),
        max_variants=args.max_variants,
    )

    print(f"[DONE] {out_dir.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
