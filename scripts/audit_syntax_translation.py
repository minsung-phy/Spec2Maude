#!/usr/bin/env python3
"""Audit the generated SpecTec carrier syntax/typecheck layer.

The script checks properties that are easy to regress by visual inspection:

* source syntax constructors should use the Spectec carrier/typecheck shape;
* conditional constructor typecheck cases should have corresponding cmb axioms;
* constructors with cmb axioms should be partial (~>) at the op declaration;
* partial constructor declarations should have a corresponding cmb witness;
* nullary constructors should not get terminal mb/cmb axioms;
* non-ground argument constructors should not get unconditional terminal mb;
* source syntax declarations should have corresponding syn-* SpectecType witnesses;
* old internal variable names such as JHS-T, NTC, iN- should not leak into output.

It intentionally audits generated output, not the SpecTec source itself.
Translator legacy-constructor references are reported as warnings by default if
they appear, because older compatibility registry lookups are not direct
generated syntax output. Pass --strict-translator to make them failures.
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
    result_sort: str


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
        r"^\s*op\s+(.+?)\s*:\s*(.*?)\s+(~>|->)\s+(SpectecTerminal|SpectecType)\b"
    )
    for line_no, line in enumerate(text.splitlines(), 1):
        m = op_re.match(line)
        if not m:
            continue
        surface = normalize_ws(m.group(1))
        arg_sorts = normalize_ws(m.group(2))
        surface_holes = sum(1 for part in surface.split() if part == "_")
        arg_count = 0 if not arg_sorts else len(arg_sorts.split())
        arity = surface_holes if surface_holes > 0 else arg_count
        decls.append(OpDecl(surface, arg_sorts, m.group(3), arity, line_no, m.group(4)))
    return decls


def split_top_level_commas(text: str) -> list[str]:
    parts: list[str] = []
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
        elif not quote and depth == 0 and ch == ",":
            part = text[start:i].strip()
            if part:
                parts.append(part)
            start = i + 1
    tail = text[start:].strip()
    if tail:
        parts.append(tail)
    return parts


def parse_prefix_call(text: str) -> tuple[str, list[str]] | None:
    text = strip_outer_parens(text)
    m = re.match(r"^([A-Za-z_$][A-Za-z0-9_$-]*)\s*\((.*)\)$", text, re.S)
    if not m:
        return None
    return m.group(1), split_top_level_commas(m.group(2))


def match_surface(surface: str, lhs: str) -> bool:
    prefix = parse_prefix_call(lhs)
    if "_" not in surface.split():
        arity = len(surface.split()) - 1 if " " in surface else None
        if prefix is None:
            return lhs_key(lhs) == surface
        head, args = prefix
        return head == surface and (arity is None or len(args) == arity)
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
    prefix = parse_prefix_call(lhs)
    if prefix is not None:
        head, args = prefix
        return [
            decl
            for decl in op_decls
            if decl.surface == head and decl.holes == len(args)
        ]
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
    vars_: set[str] = set()
    for m in re.finditer(r"\b([A-Z][A-Z0-9_-]*)\b", lhs):
        rest = lhs[m.end() :]
        if re.match(r"\s*\(", rest):
            continue
        vars_.add(m.group(1))
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


def condition_has_lhs_membership(cond: str, lhs: str) -> bool:
    normalized = normalize_ws(cond)
    candidates = [
        normalize_ws(f"( {lhs} ) : SpectecTerminal"),
        normalize_ws(f"{lhs} : SpectecTerminal"),
    ]
    return any(candidate in normalized for candidate in candidates)


def source_key(text: str) -> str:
    text = text.strip().strip("`")
    text = re.sub(r"[^A-Za-z0-9_$]+", "-", text)
    text = re.sub(r"-+", "-", text).strip("-")
    return text


def source_syntax_type_key(text: str) -> str:
    return source_key(text).strip("-_")


def audit_source_syntax_type_witnesses(
    source_dir: Path, op_decls: list[OpDecl]
) -> list[str]:
    if not source_dir.exists():
        return [f"source directory not found for syntax witness audit: {source_dir}"]

    source_types: list[tuple[Path, int, str, str]] = []
    syntax_re = re.compile(r"^\s*syntax\s+([A-Za-z_$][A-Za-z0-9_$'-]*)")
    for path in sorted(source_dir.rglob("*.spectec")):
        for line_no, raw in enumerate(path.read_text(errors="ignore").splitlines(), 1):
            line = raw.split("---", 1)[0]
            m = syntax_re.match(line)
            if not m:
                continue
            raw_name = m.group(1)
            key = source_syntax_type_key(raw_name)
            if not key or key == "list":
                continue
            source_types.append((path, line_no, raw_name, key))

    generated_type_ops = {
        decl.surface for decl in op_decls if decl.result_sort == "SpectecType"
    }
    failures: list[str] = []
    for path, line_no, raw_name, key in source_types:
        expected = f"syn-{key}"
        if expected not in generated_type_ops:
            failures.append(
                f"missing SpectecType witness for source syntax '{raw_name}' "
                f"from {path}:{line_no}; expected op {expected}"
            )
    return failures


def audit_source_type_constructor_overlap(
    source_dir: Path, op_decls: list[OpDecl]
) -> list[str]:
    if not source_dir.exists():
        return [f"source directory not found for SpectecType audit: {source_dir}"]

    type_heads: set[str] = set()
    alt_heads: set[str] = set()
    syntax_re = re.compile(r"^\s*syntax\s+([A-Za-z_$][A-Za-z0-9_$'-]*)")
    alt_re = re.compile(r"^\s*\|\s*([A-Za-z_$][A-Za-z0-9_.$'-]*)")
    for path in sorted(source_dir.rglob("*.spectec")):
        for raw in path.read_text(errors="ignore").splitlines():
            line = raw.split("---", 1)[0]
            m = syntax_re.match(line)
            if m:
                type_heads.add(source_key(m.group(1)))
            m = alt_re.match(line)
            if m:
                alt_heads.add(source_key(m.group(1)))

    overlaps = sorted(h for h in alt_heads & type_heads if h)
    if not overlaps:
        return []

    terminal_ops = {
        (decl.surface, decl.holes)
        for decl in op_decls
        if decl.result_sort == "SpectecTerminal"
    }
    type_ops = {
        (decl.surface, decl.holes)
        for decl in op_decls
        if decl.result_sort == "SpectecType"
    }
    warnings: list[str] = []
    for head in overlaps:
        terminal_arities = sorted(arity for surface, arity in terminal_ops if surface == head)
        type_arities = sorted(arity for surface, arity in type_ops if surface == head)
        if terminal_arities and not type_arities:
            warnings.append(
                "source head appears both as syntax alternative and syntax type name, "
                f"but only SpectecTerminal op was generated: {head}"
            )
        elif terminal_arities and type_arities:
            warnings.append(
                "source head appears in both terminal/type roles and has both generated op families: "
                f"{head} terminal arities={terminal_arities}, type arities={type_arities}"
            )
    return warnings


def audit_generated_terminal_type_overlaps(op_decls: list[OpDecl]) -> list[str]:
    terminal_ops = {
        (decl.surface, decl.holes)
        for decl in op_decls
        if decl.result_sort == "SpectecTerminal"
    }
    type_ops = {
        (decl.surface, decl.holes)
        for decl in op_decls
        if decl.result_sort == "SpectecType"
    }
    overlaps = sorted(terminal_ops & type_ops)
    return [
        "generated op has both SpectecTerminal and SpectecType result roles: "
        f"{surface}/{arity}"
        for surface, arity in overlaps
    ]


def audit_output(output_path: Path, source_dir: Path) -> tuple[list[str], list[str]]:
    text = output_path.read_text()
    statements = collect_statements(text)
    ops = parse_op_decls(text)
    terminal_ops = [decl for decl in ops if decl.result_sort == "SpectecTerminal"]
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

    nullary = {decl.surface: decl for decl in terminal_ops if decl.holes == 0}
    for line, kind, lhs in memberships:
        if lhs in nullary:
            failures.append(
                f"nullary constructor has terminal {kind}: {lhs} at {output_path}:{line}"
            )
        if kind == "mb":
            matches = [decl for decl in matching_ops(terminal_ops, lhs) if decl.holes > 0]
            if matches and lhs_vars(lhs):
                failures.append(
                    f"non-ground constructor has unconditional terminal mb: "
                    f"'{lhs}' at {output_path}:{line}"
                )

    cmb_op_keys: set[tuple[str, int]] = set()
    for line, kind, lhs in memberships:
        if kind != "cmb":
            continue
        matches = matching_ops(terminal_ops, lhs)
        if not matches:
            warnings.append(f"no op declaration matched cmb lhs '{lhs}' at {output_path}:{line}")
            continue
        for decl in matches:
            cmb_op_keys.add((decl.surface, decl.holes))
        if any(decl.holes > 0 and decl.arrow == "->" for decl in matches):
            bad = [decl for decl in matches if decl.holes > 0 and decl.arrow == "->"]
            failures.append(
                f"cmb lhs '{lhs}' is declared total instead of partial; "
                f"op line(s): {', '.join(str(d.line) for d in bad)}"
            )

    for decl in terminal_ops:
        if decl.holes > 0 and decl.arrow == "~>" and (decl.surface, decl.holes) not in cmb_op_keys:
            failures.append(
                f"partial constructor op has no generated cmb witness: "
                f"'{decl.surface}/{decl.holes}' at {output_path}:{decl.line}"
            )

    for line, lhs, cond in parse_constructor_typechecks(statements):
        matches = [decl for decl in matching_ops(terminal_ops, lhs) if decl.holes > 0]
        if not matches:
            continue
        actual_arg_guard = condition_has_actual_arg_guard(cond, lhs_vars(lhs))
        if actual_arg_guard and lhs not in all_memberships:
            failures.append(
                f"missing terminal cmb/mb for conditional constructor typecheck "
                f"'{lhs}' at {output_path}:{line}"
            )
        if actual_arg_guard and lhs in all_memberships:
            failures.append(
                f"constructor typecheck duplicates actual argument guard instead of "
                f"using terminal membership for '{lhs}' at {output_path}:{line}"
            )
        if lhs in all_memberships and not condition_has_lhs_membership(cond, lhs):
            failures.append(
                f"constructor typecheck with terminal membership does not guard on "
                f"'{lhs} : SpectecTerminal' at {output_path}:{line}"
            )

    concrete_patterns = [
        r"typecheck\s*\(\s*\(\s*(ADD|SUB|MUL|DIV|REM|AND|OR|XOR|SHL|SHR|ROTL|ROTR)\b.*,\s*binop\s*\(\s*(I32|I64)\s*\)",
        r"typecheck\s*\(\s*\(\s*(EQ|NE|LT|GT|LE|GE)\b.*,\s*relop\s*\(\s*(I32|I64)\s*\)",
    ]
    for pattern in concrete_patterns:
        if re.search(pattern, text):
            failures.append("parameterized binop/relop was flattened to concrete I32/I64 cases")
            break

    failures.extend(audit_source_syntax_type_witnesses(source_dir, ops))
    warnings.extend(audit_source_type_constructor_overlap(source_dir, ops))
    warnings.extend(audit_generated_terminal_type_overlaps(ops))

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
    parser.add_argument("--source-dir", default="wasm-3.0")
    parser.add_argument("--strict-translator", action="store_true")
    args = parser.parse_args()

    output_path = Path(args.output)
    translator_path = Path(args.translator)
    source_dir = Path(args.source_dir)
    failures, warnings = audit_output(output_path, source_dir)
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
