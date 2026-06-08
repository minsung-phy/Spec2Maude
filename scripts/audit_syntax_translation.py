#!/usr/bin/env python3
"""Audit the generated JHS-style SpecTec syntax/typecheck layer.

The script checks properties that are easy to regress by visual inspection:

* source syntax constructors should use the Spectec carrier/typecheck shape;
* conditional constructor typecheck cases should have corresponding cmb axioms;
* constructors with cmb axioms should be partial (~>) at the op declaration;
* nullary constructors should not get terminal mb/cmb axioms;
* old internal names such as JHS-T, NTC, iN- should not leak into output.

It intentionally audits generated output, not the SpecTec source itself.
Translator legacy-constructor references are reported as warnings by default,
because some are compatibility registry lookups rather than direct generated
syntax output. Pass --strict-translator to make them failures.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class OpDecl:
    surface: str
    arg_sorts: str
    arrow: str
    holes: int
    line: int


def normalize_ws(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip())


def strip_outer_parens(text: str) -> str:
    text = text.strip()
    while len(text) >= 2 and text[0] == "(" and text[-1] == ")":
        depth = 0
        ok = True
        for i, ch in enumerate(text):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0 and i != len(text) - 1:
                    ok = False
                    break
        if not ok or depth != 0:
            break
        text = text[1:-1].strip()
    return text


def split_top_level_terms(text: str) -> list[str]:
    text = strip_outer_parens(text)
    terms: list[str] = []
    start = 0
    depth = 0
    quote = False
    for i, ch in enumerate(text):
        if ch == "'":
            quote = not quote
        elif not quote and ch in "([{":
            depth += 1
        elif not quote and ch in ")]}":
            depth = max(0, depth - 1)
        elif not quote and depth == 0 and ch.isspace():
            part = text[start:i].strip()
            if part:
                terms.append(part)
            start = i + 1
    tail = text[start:].strip()
    if tail:
        terms.append(tail)
    return terms


def collect_statements(text: str) -> list[tuple[int, str]]:
    stmts: list[tuple[int, str]] = []
    buf: list[str] = []
    start_line = 1
    for line_no, line in enumerate(text.splitlines(), 1):
        if not buf:
            start_line = line_no
        stripped = line.strip()
        if not buf and (not stripped or stripped.startswith("---")):
            continue
        buf.append(line)
        if stripped.endswith("."):
            stmts.append((start_line, "\n".join(buf)))
            buf = []
    if buf:
        stmts.append((start_line, "\n".join(buf)))
    return stmts


def parse_op_decls(text: str) -> list[OpDecl]:
    decls: list[OpDecl] = []
    op_re = re.compile(
        r"^\s*op\s+(.+?)\s*:\s+(.+?)\s+(~>|->)\s+SpectecTerminal\b"
    )
    for line_no, line in enumerate(text.splitlines(), 1):
        m = op_re.match(line)
        if not m:
            continue
        surface = normalize_ws(m.group(1))
        holes = sum(1 for part in surface.split() if part == "_")
        decls.append(OpDecl(surface, normalize_ws(m.group(2)), m.group(3), holes, line_no))
    return decls


def match_surface(surface: str, lhs: str) -> bool:
    pattern = surface.split()
    terms = split_top_level_terms(lhs)
    i = 0
    for part in pattern:
        if part == "_":
            if i >= len(terms):
                return False
            i += 1
        else:
            if i >= len(terms) or terms[i] != part:
                return False
            i += 1
    return i == len(terms)


def matching_ops(op_decls: list[OpDecl], lhs: str) -> list[OpDecl]:
    return [decl for decl in op_decls if match_surface(decl.surface, lhs)]


def lhs_key(lhs: str) -> str:
    return normalize_ws(strip_outer_parens(lhs))


def parse_terminal_memberships(statements: list[tuple[int, str]]) -> tuple[set[str], set[str], list[tuple[int, str, str]]]:
    mb: set[str] = set()
    cmb: set[str] = set()
    entries: list[tuple[int, str, str]] = []
    memb_re = re.compile(r"\b(c?mb)\s*\(\s*(.*?)\s*\)\s*:\s*SpectecTerminal\b", re.S)
    for line, stmt in statements:
        m = memb_re.search(stmt)
        if not m:
            continue
        kind = m.group(1)
        lhs = lhs_key(m.group(2))
        entries.append((line, kind, lhs))
        if kind == "cmb":
            cmb.add(lhs)
        else:
            mb.add(lhs)
    return mb, cmb, entries


def parse_constructor_typechecks(statements: list[tuple[int, str]]) -> list[tuple[int, str, str]]:
    out: list[tuple[int, str, str]] = []
    tc_re = re.compile(
        r"\bceq\s+typecheck\s*\(\s*\(\s*(.*?)\s*\)\s*,\s*(.*?)\s*\)\s*=\s*true\s+if\s+(.*?)\s*\.\s*$",
        re.S,
    )
    for line, stmt in statements:
        m = tc_re.search(stmt)
        if not m:
            continue
        out.append((line, lhs_key(m.group(1)), normalize_ws(m.group(3))))
    return out


def condition_typecheck_vars(cond: str) -> set[str]:
    vars_: set[str] = set()
    for m in re.finditer(r"typecheck\s*\(\s*([A-Z][A-Z0-9_-]*)\b\s*,", cond):
        vars_.add(m.group(1))
    return vars_


def lhs_vars(lhs: str) -> set[str]:
    tokens = split_top_level_terms(lhs)
    vars_: set[str] = set()
    for tok in tokens:
        if re.match(r"^[A-Z][A-Z0-9_-]*$", tok):
            vars_.add(tok)
    return vars_


def condition_has_actual_arg_guard(cond: str, lhs_vars_: set[str]) -> bool:
    for part in re.split(r"\s*/\\\s*", cond):
        if "typecheck" not in part:
            continue
        checked = re.search(r"typecheck\s*\(\s*([A-Z][A-Z0-9_-]*)\b\s*,", part)
        if not checked or checked.group(1) not in lhs_vars_:
            continue
        vars_in_atom = set(re.findall(r"\b[A-Z][A-Z0-9_-]*\b", part))
        if vars_in_atom <= lhs_vars_:
            return True
    return False


def statement_condition_has_eq_true(stmt: str) -> bool:
    m = re.search(r"\bif\b(.*)\.\s*$", stmt, re.S)
    if not m:
        return False
    return re.search(r"typecheck\s*\([^)]*\)\s*=\s*true\b", m.group(1)) is not None


def audit_output(output_path: Path) -> tuple[list[str], list[str]]:
    text = output_path.read_text()
    statements = collect_statements(text)
    ops = parse_op_decls(text)
    mb, cmb, memberships = parse_terminal_memberships(statements)
    all_memberships = mb | cmb
    failures: list[str] = []
    warnings: list[str] = []

    forbidden = [
        (r"\bJHS-T\b", "old dummy variable JHS-T leaked into output"),
        (r"\bNTC\b", "old Nat dummy variable NTC leaked into output"),
        (r"\bITC\b", "old Int dummy variable ITC leaked into output"),
        (r"\b[usi]N-\s*\(", "old uN-/sN-/iN- type constructor form leaked into output"),
        (r"\btypecheck\s*\([^,\n]+,\s*list\s*\(", "typecheck(_, list(_)) leaked into output"),
        (r"^\s*op\s+list\s*:", "list type constructor declaration leaked into output"),
    ]
    for pattern, message in forbidden:
        flags = re.M
        if re.search(pattern, text, flags):
            failures.append(message)

    for line, stmt in statements:
        if statement_condition_has_eq_true(stmt):
            failures.append(f"condition keeps trailing '= true' at {output_path}:{line}")

    nullary = {decl.surface: decl for decl in ops if decl.holes == 0}
    for line, kind, lhs in memberships:
        if lhs in nullary:
            failures.append(
                f"nullary constructor has terminal {kind}: {lhs} at {output_path}:{line}"
            )

    for line, kind, lhs in memberships:
        if kind != "cmb":
            continue
        matches = matching_ops(ops, lhs)
        if not matches:
            warnings.append(f"no op declaration matched cmb lhs '{lhs}' at {output_path}:{line}")
            continue
        if any(decl.holes > 0 and decl.arrow == "->" for decl in matches):
            bad = [decl for decl in matches if decl.holes > 0 and decl.arrow == "->"]
            failures.append(
                f"cmb lhs '{lhs}' is declared total instead of partial; "
                f"op line(s): {', '.join(str(d.line) for d in bad)}"
            )

    for line, lhs, cond in parse_constructor_typechecks(statements):
        matches = [decl for decl in matching_ops(ops, lhs) if decl.holes > 0]
        if not matches:
            continue
        actual_arg_guard = condition_has_actual_arg_guard(cond, lhs_vars(lhs))
        if actual_arg_guard and lhs not in all_memberships:
            failures.append(
                f"missing terminal cmb/mb for conditional constructor typecheck "
                f"'{lhs}' at {output_path}:{line}"
            )

    concrete_patterns = [
        r"typecheck\s*\(\s*\(\s*(ADD|SUB|MUL|DIV|REM|AND|OR|XOR|SHL|SHR|ROTL|ROTR)\b.*,\s*binop\s*\(\s*(I32|I64)\s*\)",
        r"typecheck\s*\(\s*\(\s*(EQ|NE|LT|GT|LE|GE)\b.*,\s*relop\s*\(\s*(I32|I64)\s*\)",
    ]
    for pattern in concrete_patterns:
        if re.search(pattern, text):
            failures.append("parameterized binop/relop was flattened to concrete I32/I64 cases")
            break

    return failures, warnings


def audit_translator(translator_path: Path, strict: bool) -> tuple[list[str], list[str]]:
    if not translator_path.exists():
        return [], [f"translator file not found: {translator_path}"]
    text = translator_path.read_text()
    refs = [
        (i, m.group(1))
        for i, line in enumerate(text.splitlines(), 1)
        for m in [re.search(r'source_ctor_name_of_legacy\s+"(CTOR[^"]+)"', line)]
        if m
    ]
    messages = [
        f"legacy constructor registry lookup remains at {translator_path}:{line}: {name}"
        for line, name in refs
    ]
    if strict:
        return messages, []
    return [], messages


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", nargs="?", default="output.maude")
    parser.add_argument("--translator", default="translator.ml")
    parser.add_argument("--strict-translator", action="store_true")
    args = parser.parse_args()

    output_path = Path(args.output)
    translator_path = Path(args.translator)
    failures, warnings = audit_output(output_path)
    tr_failures, tr_warnings = audit_translator(translator_path, args.strict_translator)
    failures.extend(tr_failures)
    warnings.extend(tr_warnings)

    print(f"Syntax audit: {output_path}")
    if failures:
        print(f"FAIL: {len(failures)} issue(s)")
        for msg in failures:
            print(f"  - {msg}")
    else:
        print("PASS: no required syntax/typecheck/membership failures found")
    if warnings:
        print(f"WARN: {len(warnings)} note(s)")
        for msg in warnings:
            print(f"  - {msg}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
