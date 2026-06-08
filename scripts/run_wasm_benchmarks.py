#!/usr/bin/env python3
"""Run Spec2Maude WAT/Wasm benchmark probes.

This script is intentionally split into two classes of evidence:

1. smoke-runtime cases with expected results that must pass;
2. benchmark corpus discovery cases that are classified as generated,
   unsupported, stuck, wrong-result, etc. so the paper can report coverage.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RAW_NUM_CONST_RE = re.compile(r"CONST__\(\s*(I32|I64|F32|F64)\s*,\s*([+-]?\d+)\)")
NUM_CONST_SHAPES = {
    "I32": ("I32", 32),
    "I64": ("I64", 64),
    "F32": ("F32", None),
    "F64": ("F64", None),
}
WAST_NUM_TYPES = {
    "i32": "I32",
    "i64": "I64",
    "f32": "F32",
    "f64": "F64",
}
NAN_EXPECT_RE = re.compile(r"__EXPECT_(F32|F64)_NAN__")
OFFICIAL_CORE_ROOT = ROOT / "benchmarks" / "external" / "webassembly-spec" / "test" / "core"
OFFICIAL_FEATURE_DIRS = {
    "bulk-memory",
    "exceptions",
    "gc",
    "memory64",
    "multi-memory",
    "relaxed-simd",
    "simd",
}
PROBLEM_STATUSES = {
    "STEPPED",
    "STUCK_STEP",
    "WABT_FAIL",
    "WRONG_RESULT",
    "FAIL",
    "FRONTEND_FAIL",
    "STUCK_INIT",
    "STUCK_VALIDATION",
    "UNSUPPORTED",
    "IMPORT_MISSING",
}

FRONTEND_FAILURE_STATUSES = {
    "WABT_FAIL",
    "FRONTEND_FAIL",
    "UNSUPPORTED",
}

HARNESS_MARKERS = {
    "$instantiate",
    "$mem-bytes",
    "$zero-membytes",
    "$with-mem-slice",
    "BLOCK__",
    "BLOCK ",
    "BRIF_",
    "BRIF ",
    "BRTABLE__",
    "BRTABLE ",
    "BR_",
    "BR ",
    "CALL_",
    "FRAMELBRACERBRACE___",
    "LABELLBRACERBRACE___",
    "FRAMELBRACERBRACE",
    "LABELLBRACERBRACE",
    "GLOBALGET_",
    "GLOBALGET ",
    "GLOBALSET_",
    "GLOBALSET ",
    "LOAD____",
    "LOAD ",
    "LOCALGET_",
    "LOCALGET ",
    "LOCALSET_",
    "LOCALSET ",
    "LOCALTEE_",
    "LOCALTEE ",
    "LOOP__",
    "LOOP ",
    "MEMORYCOPY__",
    "MEMORYCOPY ",
    "MEMORYFILL_",
    "MEMORYFILL ",
    "MEMORYGROW_",
    "MEMORYGROW ",
    "MEMORYINIT__",
    "MEMORYINIT ",
    "MEMORYSIZE_",
    "MEMORYSIZE ",
    "STORE____",
    "STORE ",
    "TABLECOPY__",
    "TABLECOPY ",
    "TABLEFILL_",
    "TABLEFILL ",
    "TABLEGET_",
    "TABLEGET ",
    "TABLEGROW_",
    "TABLEGROW ",
    "TABLEINIT__",
    "TABLEINIT ",
    "TABLESET_",
    "TABLESET ",
    "WIFELSE___",
    "WIFELSE ",
    "CALLREF_",
    "CALLINDIRECT__",
    "RETURNCALL_",
    "CALLREF",
    "CALLINDIRECT",
    "RETURNCALL",
    "RECStoreA10",
    "RECFrameA2",
    "generated-init-config",
    "generated-run-config",
    "previous stateful action",
    "administrative/runtime term remains",
}

BUILTIN_MARKERS = {
    "$binop",
    "$unop",
    "$testop",
    "$relop",
    "$cvtop",
    "$f",
    "$i",
    "$nbytes",
    "$ibytes",
    "$load",
    "$store",
    "$wrap",
    "$extend",
    "$trunc",
    "$nearest",
    "$sqrt",
    "$v128",
    "expected result not found",
    "expected nan result not found",
}

STATE_MUTATION_MARKERS = {
    "GLOBALSET_",
    "STORE____",
    "MEMORYGROW_",
    "MEMORYFILL_",
    "MEMORYCOPY__",
    "MEMORYINIT__",
    "DATADROP_",
    "TABLESET_",
    "TABLEGROW_",
    "TABLEFILL_",
    "TABLECOPY__",
    "TABLEINIT__",
    "ELEMDROP_",
}
DIRECT_CALL_RE = re.compile(r"(?:RETURNCALL_|CALL_)\s*\(\s*([0-9]+)\s*\)")
CALL_REF_RE = re.compile(r"(?:RETURNCALLREF_|CALLREF_)")
INDIRECT_CALL_RE = re.compile(r"(?:RETURNCALLINDIRECT__|CALLINDIRECT__)")
STATIC_REF_FUNC_CALL_RE = re.compile(
    r"REFFUNC(?:ADDR)?_\s*\(\s*([0-9]+)\s*\)\s*(?:RETURNCALLREF_|CALLREF_)"
)


@dataclass
class Result:
    suite: str
    name: str
    path: str
    mode: str
    status: str
    expected: str
    observed: str
    reason: str
    parse_status: str = ""
    validation_status: str = ""
    instantiate_status: str = ""
    step_status: str = ""
    result_status: str = ""


def failure_category(row: Result) -> str:
    if row.status not in PROBLEM_STATUSES:
        return ""
    text = " ".join(
        [
            row.status,
            row.mode,
            row.step_status,
            row.observed,
            row.reason,
        ]
    )
    lower = text.lower()
    if row.status in FRONTEND_FAILURE_STATUSES:
        return "FRONTEND_LOWERING"
    if row.status == "IMPORT_MISSING":
        return "HARNESS_STATE"
    if row.status in {"STUCK_INIT", "STUCK_VALIDATION", "STEPPED"}:
        return "HARNESS_STATE"
    if any(marker.lower() in lower for marker in HARNESS_MARKERS):
        return "HARNESS_STATE"
    if any(marker.lower() in lower for marker in BUILTIN_MARKERS):
        return "BUILTIN"
    if row.status == "WRONG_RESULT":
        return "BUILTIN"
    if row.status == "STUCK_STEP":
        return "HARNESS_STATE"
    if row.status == "FAIL":
        return "FRONTEND_LOWERING" if "parse" in lower or "lower" in lower else "HARNESS_STATE"
    return "HARNESS_STATE"


@dataclass
class MemoryDataSegment:
    memory_index: int
    offset: int
    bytes: list[int]


@dataclass
class MemoryExportState:
    pages: int
    max_pages: int | None
    data: dict[int, int]

    def write(self, offset: int, bytes_: list[int]) -> None:
        for i, byte in enumerate(bytes_):
            self.data[offset + i] = byte


@dataclass
class TableExportState:
    data: dict[int, str]

    def write(self, offset: int, refs: list[str]) -> None:
        for i, ref in enumerate(refs):
            self.data[offset + i] = ref


@dataclass
class StateFunc:
    type_term: str
    locals_term: str
    body_term: str


def run(cmd: list[str], timeout: int) -> tuple[int, str]:
    proc = None
    try:
        proc = subprocess.Popen(
            cmd,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )
        out, _ = proc.communicate(timeout=timeout)
        return proc.returncode, out
    except subprocess.TimeoutExpired as exc:
        if proc is not None:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            out, _ = proc.communicate()
        else:
            out = exc.stdout or ""
            if isinstance(out, bytes):
                out = out.decode(errors="replace")
        return 124, out + "\n[TIMEOUT]"


def unsigned_payload(value: str, bits: int) -> int:
    return int(value) % (1 << bits)


def wrapped_num_const(typ: str, value: str) -> str:
    shape = NUM_CONST_SHAPES.get(typ)
    if shape is None:
        return value
    ctor, bits = shape
    if typ == "F32":
        payload = signed_int(value, 32)
    elif typ == "F64":
        payload = signed_int(value, 64)
    else:
        payload = unsigned_payload(value, bits) if bits is not None else int(value)
    return f"CONST__({ctor}, {payload})"


def source_float_const(typ: str, value: str) -> str | None:
    if typ == "F32":
        bits, fracbits, ebits, bias = 32, 23, 8, 127
    elif typ == "F64":
        bits, fracbits, ebits, bias = 64, 52, 11, 1023
    else:
        return None
    raw = int(value) % (1 << bits)
    sign = raw >> (bits - 1)
    exp = (raw >> fracbits) & ((1 << ebits) - 1)
    frac = raw & ((1 << fracbits) - 1)
    max_exp = (1 << ebits) - 1
    if exp == 0:
        mag = f"SUBNORM_({frac})"
    elif exp == max_exp and frac == 0:
        mag = "INF"
    elif exp == max_exp:
        mag = f"NAN_({frac})"
    else:
        mag = f"NORM__({frac}, {exp - bias})"
    sign_ctor = "NEG_" if sign else "POS_"
    return f"CONST__({typ}, {sign_ctor}({mag}))"


def wrapped_numeric_equivalent(term: str) -> str:
    return RAW_NUM_CONST_RE.sub(
        lambda match: wrapped_num_const(match.group(1), match.group(2)),
        term,
    )


def source_float_equivalent(term: str) -> str:
    def repl(match: re.Match[str]) -> str:
        source = source_float_const(match.group(1), match.group(2))
        return source if source is not None else match.group(0)

    return RAW_NUM_CONST_RE.sub(repl, term)


SOURCE_FLOAT_CONST_RE = re.compile(
    r"CONST__\(\s*(F32|F64)\s*,\s*(POS_|NEG_)\((SUBNORM_|NAN_|NORM__)\(([^()]*)\)\)\s*\)"
)
SOURCE_FLOAT_INF_RE = re.compile(
    r"CONST__\(\s*(F32|F64)\s*,\s*(POS_|NEG_)\(INF\)\s*\)"
)


def maude_source_float_equivalent(term: str) -> str:
    """Render source float constants the way Maude prints trailing-underscore ops."""

    def repl_mag(match: re.Match[str]) -> str:
        typ = match.group(1)
        sign = match.group(2)[:-1]
        mag = match.group(3)[:-1].replace("NORM_", "NORM")
        args = " ".join(part.strip() for part in match.group(4).split(","))
        return f"CONST {typ} {sign}({mag} {args})"

    def repl_inf(match: re.Match[str]) -> str:
        return f"CONST {match.group(1)} {match.group(2)[:-1]} INF"

    rendered = SOURCE_FLOAT_CONST_RE.sub(repl_mag, term)
    rendered = SOURCE_FLOAT_INF_RE.sub(repl_inf, rendered)
    return rendered


def pretty_numeric_equivalent(term: str) -> str:
    return RAW_NUM_CONST_RE.sub(
        lambda match: f"CONST {match.group(1)} {match.group(2)}",
        term,
    )


def split_top_level_args(text: str) -> list[str] | None:
    args: list[str] = []
    start = 0
    depth = 0
    for index, ch in enumerate(text):
        if ch == "(":
            depth += 1
        elif ch == ")":
            if depth == 0:
                return None
            depth -= 1
        elif ch == "," and depth == 0:
            args.append(text[start:index].strip())
            start = index + 1
    if depth != 0:
        return None
    args.append(text[start:].strip())
    return args


def find_matching_paren(text: str, open_index: int) -> int | None:
    depth = 0
    for index in range(open_index, len(text)):
        ch = text[index]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return index
    return None


def readable_mixfix_equivalent(term: str) -> str:
    """Render generated prefix constructor expectations like K_(X) as K X."""
    out: list[str] = []
    index = 0
    changed = False
    while index < len(term):
        match = re.match(r"([A-Z][A-Z0-9]*)(_{1,})\(", term[index:])
        if match is None:
            out.append(term[index])
            index += 1
            continue
        name = match.group(1)
        holes = len(match.group(2))
        open_index = index + match.end() - 1
        close_index = find_matching_paren(term, open_index)
        if close_index is None:
            out.append(name + " ")
            index = open_index + 1
            changed = True
            continue
        inner = term[open_index + 1 : close_index]
        args = split_top_level_args(inner)
        if args is None or len(args) != holes:
            out.append(term[index : close_index + 1])
            index = close_index + 1
            continue
        pretty_args = [readable_mixfix_equivalent(arg).strip() for arg in args]
        out.append(" ".join([name, *pretty_args]).strip())
        index = close_index + 1
        changed = True
    rendered = "".join(out)
    return " ".join(rendered.split()) if changed else term


def append_unique(items: list[str], item: str) -> None:
    if item and item not in items:
        items.append(item)


def expected_alternatives(expected: str) -> list[str]:
    """Accept explicit expectations plus their canonical raw numeric form."""
    alternatives: list[str] = []
    for item in (part.strip() for part in expected.split(" || ")):
        if not item:
            continue
        append_unique(alternatives, item)
        mixfix = readable_mixfix_equivalent(item)
        append_unique(alternatives, mixfix)
        raw = wrapped_numeric_equivalent(item)
        if raw != item:
            append_unique(alternatives, raw)
            append_unique(alternatives, readable_mixfix_equivalent(raw))
        source_float = source_float_equivalent(raw)
        if source_float != raw:
            append_unique(alternatives, source_float)
            append_unique(alternatives, readable_mixfix_equivalent(source_float))
            append_unique(alternatives, maude_source_float_equivalent(source_float))
        pretty = pretty_numeric_equivalent(raw)
        if pretty != raw:
            append_unique(alternatives, pretty)
    return alternatives


def compact_expected_alternatives(expected: str) -> list[str]:
    alternatives: list[str] = []
    for item in expected_alternatives(expected):
        compact = " ".join(item.split())
        if compact:
            alternatives.append(compact)
    return alternatives


def whitespace_free(text: str) -> str:
    return "".join(text.split())


def maude_compare_key(text: str) -> str:
    """Normalize prefix and readable Maude result spellings for substring checks."""
    return re.sub(r"[\s(),_]+", "", text)


def wasm2wat_text(wasm: Path, timeout: int) -> str:
    code, out = run(["wasm2wat", "--enable-all", str(wasm)], timeout)
    if code != 0:
        return ""
    return out


def wat_string_bytes(literal: str) -> list[int]:
    raw = literal[1:-1] if len(literal) >= 2 and literal[0] == '"' and literal[-1] == '"' else literal
    out: list[int] = []
    i = 0
    while i < len(raw):
        ch = raw[i]
        if ch != "\\":
            out.append(ord(ch))
            i += 1
            continue
        if i + 2 < len(raw) and re.fullmatch(r"[0-9a-fA-F]{2}", raw[i + 1 : i + 3]):
            out.append(int(raw[i + 1 : i + 3], 16))
            i += 3
            continue
        if i + 1 >= len(raw):
            out.append(ord("\\"))
            i += 1
            continue
        escaped = raw[i + 1]
        escapes = {"n": 10, "t": 9, "r": 13, '"': 34, "'": 39, "\\": 92}
        out.append(escapes.get(escaped, ord(escaped)))
        i += 2
    return out


def wat_name(literal: str) -> str:
    return bytes(wat_string_bytes(literal)).decode("utf-8", errors="replace")


def quoted_wat_strings(text: str) -> list[str]:
    strings: list[str] = []
    i = 0
    while i < len(text):
        if text[i] != '"':
            i += 1
            continue
        start = i
        i += 1
        while i < len(text):
            if text[i] == "\\":
                i += 3 if i + 2 < len(text) and re.fullmatch(r"[0-9a-fA-F]{2}", text[i + 1 : i + 3]) else 2
                continue
            if text[i] == '"':
                strings.append(text[start : i + 1])
                i += 1
                break
            i += 1
    return strings


def wasm_memory_info(
    wasm: Path, timeout: int
) -> tuple[
    dict[int, tuple[int, int | None]],
    dict[int, tuple[str, str]],
    dict[str, int],
    list[MemoryDataSegment],
]:
    out = wasm2wat_text(wasm, timeout)
    memory_pages: dict[int, tuple[int, int | None]] = {}
    memory_imports: dict[int, tuple[str, str]] = {}
    exports: dict[str, int] = {}
    active_data: list[MemoryDataSegment] = []
    for line in out.splitlines():
        line = line.strip()
        m = re.match(
            r'^\(import\s+"([^"]+)"\s+"([^"]+)"\s+\(memory\s+\(;(\d+);\)\s+(?:i64\s+)?(\d+)(?:\s+(\d+))?',
            line,
        )
        if m:
            idx = int(m.group(3))
            memory_imports[idx] = (m.group(1), m.group(2))
            memory_pages[idx] = (
                int(m.group(4)),
                int(m.group(5)) if m.group(5) is not None else None,
            )
            continue
        m = re.match(r'^\(memory\s+\(;(\d+);\)\s+(?:i64\s+)?(\d+)(?:\s+(\d+))?', line)
        if m:
            memory_pages[int(m.group(1))] = (
                int(m.group(2)),
                int(m.group(3)) if m.group(3) is not None else None,
            )
            continue
        if line.startswith("(export "):
            strings = quoted_wat_strings(line)
            m = re.search(r"\(memory\s+(\d+)\)", line)
            if strings and m:
                exports[wat_name(strings[0])] = int(m.group(1))
            continue
        m = re.match(
            r'^\(data\s+\(;\d+;\)\s+(?:\(memory\s+(\d+)\)\s+)?\((?:i32|i64)\.const\s+([0-9]+)\)\s+(.*)\)$',
            line,
        )
        if m:
            memidx = int(m.group(1) or "0")
            offset = int(m.group(2))
            data_bytes: list[int] = []
            for literal in quoted_wat_strings(m.group(3)):
                data_bytes.extend(wat_string_bytes(literal))
            active_data.append(MemoryDataSegment(memidx, offset, data_bytes))
    return memory_pages, memory_imports, exports, active_data


def wasm_import_kinds(wasm: Path, timeout: int) -> set[str]:
    out = wasm2wat_text(wasm, timeout)
    kinds: set[str] = set()
    for line in out.splitlines():
        line = line.strip()
        if not line.startswith("(import "):
            continue
        for kind in ("func", "memory", "table", "global", "tag"):
            if f"({kind}" in line:
                kinds.add(kind)
                break
    return kinds


def function_export_index_from_wasm(wasm: Path, field: str, timeout: int) -> int | None:
    for line in wasm2wat_text(wasm, timeout).splitlines():
        line = line.strip()
        if not line.startswith("(export "):
            continue
        strings = quoted_wat_strings(line)
        if not strings or wat_name(strings[0]) != field:
            continue
        m = re.search(r"\(func\s+(\d+)\)", line)
        if m:
            return int(m.group(1))
    return None


def invoke_flags_for_export(wasm: Path, field: str, timeout: int) -> list[str] | None:
    funcidx = function_export_index_from_wasm(wasm, field, timeout)
    if funcidx is not None:
        return ["--invoke-index", str(funcidx), "--run-main"]
    if "\x00" in field:
        return None
    return ["--run-export", field]


def memory_exports_from_wasm(wasm: Path, timeout: int) -> dict[str, MemoryExportState]:
    memory_pages, _, exports, active_data = wasm_memory_info(wasm, timeout)
    exported: dict[str, MemoryExportState] = {}
    state_by_index: dict[int, MemoryExportState] = {}
    for name, idx in exports.items():
        if idx not in memory_pages:
            continue
        state = state_by_index.get(idx)
        if state is None:
            pages, max_pages = memory_pages[idx]
            state = MemoryExportState(pages, max_pages, {})
            for segment in active_data:
                if segment.memory_index == idx:
                    state.write(segment.offset, segment.bytes)
            state_by_index[idx] = state
        exported[name] = state
    return exported


def memory_overlay_ranges(data: dict[int, int]) -> list[tuple[int, list[int]]]:
    ranges: list[tuple[int, list[int]]] = []
    for offset in sorted(data):
        byte = data[offset]
        if not ranges:
            ranges.append((offset, [byte]))
            continue
        start, bytes_ = ranges[-1]
        if start + len(bytes_) == offset:
            bytes_.append(byte)
        else:
            ranges.append((offset, [byte]))
    return ranges


def overlay_specs(data: dict[int, int]) -> list[str]:
    return [
        f"{offset}:{','.join(str(byte) for byte in bytes_)}"
        for offset, bytes_ in memory_overlay_ranges(data)
        if bytes_
    ]


def format_import_memory_spec(module: str, name: str, state: MemoryExportState) -> str:
    limits = f"{state.pages}" + (f"/{state.max_pages}" if state.max_pages is not None else "")
    overlays = overlay_specs(state.data)
    return f"{module}.{name}={limits}" + (f"@{'@'.join(overlays)}" if overlays else "")


def format_memory_data_spec(name: str, state: MemoryExportState) -> str | None:
    overlays = overlay_specs(state.data)
    if not overlays:
        return None
    return f"{name}={'@'.join(overlays)}"


def format_table_data_spec(name: str, state: TableExportState) -> str | None:
    overlays = [f"{offset}:{state.data[offset]}" for offset in sorted(state.data)]
    if not overlays:
        return None
    return f"{name}={'@'.join(overlays)}"


def format_state_func_spec(func: StateFunc) -> str:
    return f"type={func.type_term}|locals={func.locals_term}|body={func.body_term}"


def classify_output(code: int, out: str, expected: str = "") -> tuple[str, str, str]:
    compact = " ".join(out.split())
    lower = out.lower()
    if code == 124:
        return ("TIMEOUT", "", "timeout")
    if code != 0:
        if (
            "stack overflow" in lower
            or "timeout" in lower
            or "stuck execution term" in lower
            or "did not rewrite to a concrete config" in lower
        ):
            return ("STUCK_STEP", "", first_line(out))
        if (
            "rejected invalid wat" in lower
            or "invalid wasm" in lower
            or "wasm-validate" in lower
            or "official wasm parser/validator rejected input" in lower
        ):
            return ("INVALID", "", first_line(out))
        if "wasm_to_maude:" in lower and "unsupported" in lower:
            return ("UNSUPPORTED", "", first_line(out))
        if "module has imports" in lower:
            return ("IMPORT_MISSING", "", first_line(out))
        if "module has no function to invoke" in lower:
            return ("NO_ENTRY", "", first_line(out))
        if "wasm_to_maude:" in lower and ("parse" in lower or "expected" in lower):
            return ("FRONTEND_FAIL", "", first_line(out))
        if (
            "error:" in lower
            or "invalid" in lower
            or "unable to read" in lower
            or "failed to read" in lower
            or "is a directory" in lower
        ):
            return ("WABT_FAIL", "", first_line(out))
        if "unsupported" in lower:
            return ("UNSUPPORTED", "", first_line(out))
        return ("FAIL", "", first_line(out))
    observed = ""
    marker = "result:"
    if marker in out:
        observed = out[out.rindex(marker) + len(marker) :].strip().splitlines()[0].strip()
    admin_terms = [
        "FRAMELBRACERBRACE___",
        "LABELLBRACERBRACE___",
        "FRAMELBRACERBRACE",
        "LABELLBRACERBRACE",
        "CALLREF_",
        "CALLINDIRECT__",
        "RETURNCALL_",
        "BLOCK ",
        "BR ",
        "BRIF ",
        "BRTABLE ",
        "CALL ",
        "GLOBALGET ",
        "GLOBALSET ",
        "LOAD ",
        "LOCALGET ",
        "LOCALSET ",
        "LOCALTEE ",
        "LOOP ",
        "MEMORYCOPY ",
        "MEMORYFILL ",
        "MEMORYGROW ",
        "MEMORYINIT ",
        "MEMORYSIZE ",
        "STORE ",
        "TABLECOPY ",
        "TABLEFILL ",
        "TABLEGET ",
        "TABLEGROW ",
        "TABLEINIT ",
        "TABLESET ",
        "WIFELSE ",
        "CALLREF",
        "CALLINDIRECT",
        "RETURNCALL",
    ]
    if observed and any(admin in observed for admin in admin_terms):
        return ("STUCK_STEP", observed, "administrative/runtime term remains")
    if expected:
        if "SEARCH-PASS" in compact:
            return ("PASS", "SEARCH-PASS", "")
        if "SEARCH-FAIL" in compact:
            return ("WRONG_RESULT", "SEARCH-FAIL", "expected result is not reachable")
        if (
            "generated-checked-run-config" in observed
            or "Module-ok(" in observed
            or "Module-ok(" in compact
        ):
            return ("STUCK_VALIDATION", observed or compact[-240:], "checked run did not pass Module-ok")
        if (
            "result StepsConf:" in out
            or "steps(generated-run-config" in compact
            or "steps(generated-checked-run-config" in compact
        ):
            return ("STUCK_STEP", observed or compact[-240:], "steps did not rewrite to a concrete Config")
        nan_expected = NAN_EXPECT_RE.findall(expected)
        if nan_expected:
            if all(observed_has_nan_const(observed or compact, typ) for typ in nan_expected):
                return ("PASS", observed, "")
            return ("WRONG_RESULT", observed or compact[-240:], "expected NaN result not found")
        expected_items = compact_expected_alternatives(expected)
        compact_no_ws = whitespace_free(compact)
        compact_key = maude_compare_key(compact)
        if any(
            item in compact or whitespace_free(item) in compact_no_ws
            or maude_compare_key(item) in compact_key
            for item in expected_items
        ):
            return ("PASS", observed, "")
        return ("WRONG_RESULT", observed or compact[-240:], "expected result not found")
    return ("GENERATED", observed, "")


def classify_instantiate_output(code: int, out: str) -> tuple[str, str, str]:
    compact = " ".join(out.split())
    lower = out.lower()
    if code == 124:
        return ("STUCK_INIT", "", "timeout")
    if code != 0:
        if "unsupported" in lower:
            return ("UNSUPPORTED", "", first_line(out))
        if "error:" in lower or "warning:" in lower:
            return ("STUCK_INIT", "", first_line(out))
        return ("STUCK_INIT", "", first_line(out))
    if "result Config:" in out:
        return ("INSTANTIATED", "Config", "")
    if "$instantiate" in compact or "generated-init-config" in compact:
        return ("STUCK_INIT", compact[-240:], "instantiate did not rewrite to a concrete config")
    return ("STUCK_INIT", compact[-240:], "no concrete Config result")


def classify_validation_output(code: int, out: str) -> tuple[str, str, str]:
    compact = " ".join(out.split())
    lower = out.lower()
    if code == 124:
        return ("STUCK_VALIDATION", "", "timeout")
    if code != 0:
        if "unsupported" in lower:
            return ("UNSUPPORTED", "", first_line(out))
        if "error:" in lower or "warning:" in lower:
            return ("STUCK_VALIDATION", "", first_line(out))
        return ("STUCK_VALIDATION", "", first_line(out))
    if "result ValidJudgement: valid" in out:
        return ("VALIDATED", "valid", "")
    if "Module-ok(" in compact or "generated-module-type" in compact:
        return ("INVALID", compact[-240:], "Module-ok did not rewrite to valid")
    return ("INVALID", compact[-240:], "no valid judgement")


def classify_step_output(code: int, out: str, expected: str = "") -> tuple[str, str, str]:
    status, observed, reason = classify_output(code, out, expected)
    if status == "GENERATED":
        return ("STEPPED", observed, reason)
    if status == "TIMEOUT":
        return ("STUCK_STEP", observed, reason)
    if status == "FAIL" and ("steps(" in out or "result StepsConf" in out):
        return ("STUCK_STEP", observed, reason)
    return (status, observed, reason)


def first_line(out: str) -> str:
    for line in out.splitlines():
        line = line.strip()
        if line:
            return line[:240]
    return ""


def cli_prefix(cli: str) -> list[str]:
    return cli.split()


def state_effects_from_wasm(cli: str, wasm: Path, timeout: int) -> dict:
    code, out = run(cli_prefix(cli) + ["--dump-state-effects", str(wasm)], timeout)
    if code != 0:
        code, out = run(
            cli_prefix(cli) + ["--legacy-wat-parser", "--dump-state-effects", str(wasm)],
            timeout,
        )
    if code != 0:
        return {"funcs": [], "table_imports": [], "table_exports": [], "active_elems": []}
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return {"funcs": [], "table_imports": [], "table_exports": [], "active_elems": []}
    for key in ("funcs", "table_imports", "table_exports", "active_elems"):
        if not isinstance(data.get(key), list):
            data[key] = []
    return data


def smoke_cases() -> list[tuple[str, list[str], str]]:
    return [
        (
            "fib",
            ["--unchecked-run", "--result-only", "--run", "5", "wat_examples/fib.wat"],
            "CONST__(I32, 5)",
        ),
        (
            "fib-wrapper",
            [
                "--result-only",
                "--unchecked-run",
                "--run-export",
                "wrapper",
                "--arg-i32",
                "5",
                "--arg-i32",
                "0",
                "--arg-i32",
                "1",
                "wat_examples/fib-wrapper.wat",
            ],
            "CONST__(I32, 5)",
        ),
        (
            "global-get",
            ["--unchecked-run", "--result-only", "--run-main", "wat_examples/global-get.wat"],
            "CONST__(I32, 42)",
        ),
        (
            "memory-size",
            ["--unchecked-run", "--result-only", "--run-main", "wat_examples/memory-size.wat"],
            "CONST__(I32, 0)",
        ),
        (
            "table-size",
            ["--unchecked-run", "--result-only", "--run-main", "wat_examples/table-size.wat"],
            "CONST__(I32, 3)",
        ),
        (
            "start-global",
            ["--unchecked-run", "--result-only", "--run-main", "wat_examples/start-global.wat"],
            "CONST__(I32, 7)",
        ),
        (
            "data-load",
            ["--unchecked-run", "--result-only", "--run-main", "wat_examples/data-load.wat"],
            "CONST__(I32, 42)",
        ),
        (
            "elem-call-ref",
            ["--unchecked-run", "--result-only", "--run-main", "wat_examples/elem-call-ref.wat"],
            "CONST__(I32, 9)",
        ),
        (
            "import-func",
            [
                "--result-only",
                "--unchecked-run",
                "--run-export",
                "main",
                "--arg-i32",
                "41",
                "--import-func",
                "env.bump=local.get 0 i32.const 1 i32.add",
                "wat_examples/import-func.wat",
            ],
            "CONST__(I32, 42)",
        ),
        (
            "import-global",
            [
                "--result-only",
                "--unchecked-run",
                "--run-export",
                "main",
                "--import-global",
                "env.g=i32.const 77",
                "wat_examples/import-global.wat",
            ],
            "CONST__(I32, 77)",
        ),
        (
            "import-memory",
            ["--unchecked-run", "--result-only", "--run-export", "main", "wat_examples/import-memory.wat"],
            "CONST__(I32, 1)",
        ),
        (
            "import-table",
            ["--unchecked-run", "--result-only", "--run-export", "main", "wat_examples/import-table.wat"],
            "CONST__(I32, 4)",
        ),
    ]


def run_smokes(cli: str, maude: str, timeout: int) -> list[Result]:
    results: list[Result] = []
    for name, args, expected in smoke_cases():
        cmd = cli_prefix(cli) + ["--maude", maude] + args
        code, out = run(cmd, timeout)
        status, observed, reason = classify_output(code, out, expected)
        results.append(
            Result(
                "wat_examples",
                name,
                args[-1],
                "runtime",
                status,
                expected,
                observed,
                reason,
                parse_status="GENERATED" if status == "PASS" else "",
                validation_status="VALIDATED" if status == "PASS" else "",
                instantiate_status="INSTANTIATED" if status == "PASS" else "",
                step_status="STEPPED" if status == "PASS" else "",
                result_status=status,
            )
        )
    return results


def invalid_cases() -> list[Path]:
    return [ROOT / "wat_examples" / "invalid-result-type.wat"]


def classify_checked_run_block_output(code: int, out: str) -> tuple[str, str, str]:
    compact = " ".join(out.split())
    if code == 124:
        return ("STUCK_VALIDATION", "", "timeout")
    if code != 0:
        return ("STUCK_VALIDATION", "", first_line(out))
    if "generated-checked-run-config" in compact or "Module-ok(" in compact:
        return ("PASS", compact[-240:], "")
    if "steps(" in compact or "result Config:" in out or "TRAP" in compact:
        return ("WRONG_RESULT", compact[-240:], "invalid module reached runtime")
    return ("PASS", compact[-240:], "")


def run_invalid_smokes(cli: str, maude: str, timeout: int) -> list[Result]:
    results: list[Result] = []
    for path in invalid_cases():
        rel = str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path)
        if not path.exists():
            results.append(
                Result(
                    "wat_examples_invalid",
                    path.stem,
                    rel,
                    "invalid",
                    "FAIL",
                    "INVALID",
                    "",
                    "missing invalid smoke input",
                    result_status="FAIL",
                )
            )
            continue

        code, out = run(
            cli_prefix(cli) + ["--maude", maude, "--unchecked-run", "--result-only", "--run-main", str(path)],
            timeout,
        )
        status, observed, reason = classify_output(code, out)
        frontend_status = "PASS" if status in {"WABT_FAIL", "INVALID"} else "WRONG_RESULT"
        results.append(
            Result(
                "wat_examples_invalid",
                path.stem + ":frontend",
                rel,
                "invalid-frontend",
                frontend_status,
                "frontend rejects invalid WAT",
                observed,
                reason if frontend_status == "PASS" else f"unexpected status: {status}",
                parse_status=status,
                result_status=frontend_status,
            )
        )

    return results


def discover_bench_files(roots: list[Path]) -> list[Path]:
    files: list[Path] = []
    for root in roots:
        if root.is_file():
            files.append(root)
            continue
        if not root.exists():
            continue
        for ext in ("*.wat", "*.wasm", "*.wast"):
            files.extend(path for path in root.rglob(ext) if path.is_file())
    def key(path: Path) -> tuple[int, int, str]:
        suite_priority = 0 if "webassembly-spec" in path.parts else 1
        try:
            size = path.stat().st_size
        except OSError:
            size = 0
        return (suite_priority, size, str(path))

    return sorted(set(files), key=key)


def feature_of_path(path_text: str) -> str:
    path = Path(path_text)
    try:
        rel = path.relative_to(OFFICIAL_CORE_ROOT)
    except ValueError:
        try:
            rel = path.relative_to(ROOT)
        except ValueError:
            rel = path
    parts = rel.parts
    if not parts:
        return "unknown"
    if parts[0] in OFFICIAL_FEATURE_DIRS:
        return parts[0]
    if "webassembly-spec" in path.parts:
        return "core"
    if len(parts) >= 2:
        return parts[0]
    return path.parent.name or "unknown"


def generated_maude_command(maude: str, generated: Path, command: str, timeout: int) -> tuple[int, str]:
    with tempfile.NamedTemporaryFile("w", suffix=".maude", delete=False) as cmd_file:
        cmd_file.write(f"load {generated}\n{command}\nq\n")
        cmd_path = Path(cmd_file.name)
    try:
        return run([maude, str(cmd_path)], timeout)
    finally:
        try:
            cmd_path.unlink()
        except OSError:
            pass


def run_generate(
    cli: str,
    path: Path,
    timeout: int,
    out_path: Path,
    extra_args: list[str] | None = None,
) -> tuple[str, str, str]:
    code, out = run(
        cli_prefix(cli)
        + (extra_args or [])
        + ["--output", str(out_path), str(path)],
        timeout,
    )
    return classify_output(code, out)


def run_instantiate_stage(maude: str, generated: Path, timeout: int) -> tuple[str, str, str]:
    code, out = generated_maude_command(
        maude,
        generated,
        "rew [10000] in WASM-FIB-GENERATED : generated-init-config .",
        timeout,
    )
    return classify_instantiate_output(code, out)


def run_validation_stage(maude: str, generated: Path, timeout: int) -> tuple[str, str, str]:
    code, out = generated_maude_command(
        maude,
        generated,
        "rew [10000] in WASM-FIB-GENERATED : Module-ok(generated-fib-module, generated-module-type) .",
        timeout,
    )
    return classify_validation_output(code, out)


def run_step_stage(
    cli: str,
    maude: str,
    path: Path,
    timeout: int,
    expected: str = "",
    rewrite_limit: int = 10000,
) -> tuple[str, str, str]:
    code, out = run(
        cli_prefix(cli)
        + [
            "--maude",
            maude,
            "--unchecked-run",
            "--result-only",
            "--rewrite-limit",
            str(rewrite_limit),
            "--run-main",
            str(path),
        ],
        timeout,
    )
    return classify_step_output(code, out, expected)


def run_stage_probe(
    cli: str,
    maude: str,
    path: Path,
    timeout: int,
    suite: str = "external",
    mode: str = "stage",
    rewrite_limit: int = 10000,
    extra_cli_args: list[str] | None = None,
) -> Result:
    rel = str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path)
    with tempfile.TemporaryDirectory(prefix="spec2maude-stage-") as tmpdir:
        generated = Path(tmpdir) / "generated.maude"
        gen_status, gen_observed, gen_reason = run_generate(
            cli, path, timeout, generated, extra_cli_args
        )
        if gen_status != "GENERATED":
            return Result(
                suite,
                path.stem,
                rel,
                mode,
                gen_status,
                "",
                gen_observed,
                gen_reason,
                parse_status=gen_status,
                result_status=gen_status,
            )
        init_status, init_observed, init_reason = run_instantiate_stage(maude, generated, timeout)
        if init_status != "INSTANTIATED":
            return Result(
                suite,
                path.stem,
                rel,
                mode,
                init_status,
                "",
                init_observed,
                init_reason,
                parse_status="GENERATED",
                validation_status="FRONTEND_VALIDATED",
                instantiate_status=init_status,
                result_status=init_status,
            )
        if mode == "wast-module-stage":
            return Result(
                suite,
                path.stem,
                rel,
                mode,
                "MODULE_STAGE",
                "",
                "",
                "module-stage probe instantiated without an expected assertion",
                parse_status="GENERATED",
                validation_status="FRONTEND_VALIDATED",
                instantiate_status="INSTANTIATED",
                step_status="MODULE_STAGE",
                result_status="MODULE_STAGE",
            )
        step_status, step_observed, step_reason = run_step_stage(
            cli, maude, path, timeout, rewrite_limit=rewrite_limit
        )
        final_status = (
            "MODULE_STAGE"
            if mode == "wast-module-stage" and step_status == "STEPPED"
            else step_status
        )
        reason = (
            "module-stage probe terminated without an expected assertion"
            if final_status == "MODULE_STAGE"
            else step_reason
        )
        return Result(
            suite,
            path.stem,
            rel,
            mode,
            final_status,
            "",
            step_observed,
            reason,
            parse_status="GENERATED",
            validation_status="FRONTEND_VALIDATED",
            instantiate_status="INSTANTIATED",
            step_status=step_status,
            result_status=final_status,
        )


def signed_int(value: str, bits: int) -> int:
    n = int(value)
    mod = 1 << bits
    half = 1 << (bits - 1)
    n %= mod
    if n >= half:
        n -= mod
    return n


def is_nan_bits(value: int, bits: int) -> bool:
    if bits == 32:
        value %= 1 << 32
        return (value & 0x7F800000) == 0x7F800000 and (value & 0x007FFFFF) != 0
    if bits == 64:
        value %= 1 << 64
        return (value & 0x7FF0000000000000) == 0x7FF0000000000000 and (value & 0x000FFFFFFFFFFFFF) != 0
    return False


def observed_has_nan_const(text: str, typ: str) -> bool:
    if typ == "F32":
        ctor, bits = "F32", 32
    elif typ == "F64":
        ctor, bits = "F64", 64
    else:
        return False
    raw_pattern = re.compile(
        rf"CONST__\s*\(\s*{ctor}\s*,\s*([+-]?\d+)\s*\)"
    )
    pretty_pattern = re.compile(rf"\bCONST\s+{ctor}\s+([+-]?\d+)\b")
    source_pattern = re.compile(
        rf"(?:CONST__\s*\(\s*{ctor}\s*,\s*(?:POS_|NEG_)\s*\(\s*NAN_|"
        rf"\bCONST\s+{ctor}\s+(?:POS|NEG)\s+NAN\b)"
    )
    return (
        any(is_nan_bits(int(match.group(1)), bits) for match in raw_pattern.finditer(text))
        or any(is_nan_bits(int(match.group(1)), bits) for match in pretty_pattern.finditer(text))
        or source_pattern.search(text) is not None
    )


def packed_v128_lanes(value: str) -> int | None:
    lanes = [part for part in value.split() if part]
    if not lanes:
        return None
    if any(re.fullmatch(r"[+-]?\d+", lane) is None for lane in lanes):
        return None
    width_by_count = {16: 8, 8: 16, 4: 32, 2: 64, 1: 128}
    width = width_by_count.get(len(lanes))
    if width is None:
        return None
    packed = 0
    mask = (1 << width) - 1
    for i, lane in enumerate(lanes):
        packed |= (int(lane) & mask) << (i * width)
    return packed


REF_HEAPTYPES = {
    "funcref": "FUNC",
    "externref": "EXTERN",
    "anyref": "ANY",
    "eqref": "WEQ",
    "i31ref": "I31",
    "structref": "STRUCT",
    "arrayref": "ARRAY",
    "exnref": "EXN",
    "nullref": "NONE",
    "nullfuncref": "NOFUNC",
    "nullexnref": "NOEXN",
    "nullexternref": "NOEXTERN",
    "refnull": "NONE",
}

NULL_REF_ALTERNATIVES = {
    "anyref": ["ANY", "NONE"],
    "funcref": ["FUNC", "NOFUNC"],
    "exnref": ["EXN", "NOEXN"],
    "externref": ["EXTERN", "NOEXTERN"],
    "eqref": ["WEQ", "NONE"],
    "i31ref": ["I31", "NONE"],
    "structref": ["STRUCT", "NONE"],
    "arrayref": ["ARRAY", "NONE"],
    "nullref": ["NONE"],
    "nullfuncref": ["NOFUNC"],
    "nullexnref": ["NOEXN"],
    "nullexternref": ["NOEXTERN"],
    "refnull": ["ANY", "NONE", "FUNC", "NOFUNC", "EXN", "NOEXN", "EXTERN", "NOEXTERN"],
}

REF_ARG_FLAGS = {
    "funcref": "--arg-funcref",
    "externref": "--arg-externref",
    "anyref": "--arg-anyref",
    "eqref": "--arg-eqref",
    "i31ref": "--arg-i31ref",
    "structref": "--arg-structref",
    "arrayref": "--arg-arrayref",
    "exnref": "--arg-exnref",
}

REF_VALUE_CTORS = {
    "funcref": ["REFFUNCADDR_"],
    "externref": ["REFEXTERN_"],
    "anyref": [
        "REFHOSTADDR_",
        "REFEXTERN_",
        "REFFUNCADDR_",
        "REFI31NUM_",
        "REFSTRUCTADDR_",
        "REFARRAYADDR_",
    ],
    "eqref": ["REFI31NUM_", "REFSTRUCTADDR_", "REFARRAYADDR_"],
    "i31ref": ["REFI31NUM_"],
    "structref": ["REFSTRUCTADDR_"],
    "arrayref": ["REFARRAYADDR_"],
    "exnref": ["REFEXNADDR_"],
}


def maude_ref_alternatives(typ: str, value: str | None) -> list[str] | None:
    heap = REF_HEAPTYPES.get(typ)
    ctors = REF_VALUE_CTORS.get(typ)
    null_heaps = NULL_REF_ALTERNATIVES.get(typ)
    if typ == "refnull" and value is None:
        return ["REFNULL_("]
    if value == "null" or (value is None and null_heaps is not None):
        return [f"REFNULL_({heap})" for heap in (null_heaps or [heap]) if heap is not None]
    if heap is None or ctors is None:
        return None
    if value is None:
        return [f"{ctor}(" for ctor in ctors]
    if typ == "externref":
        return [
            f"REFEXTERN_({value})",
            f"REFEXTERN_(REFHOSTADDR_({value}))",
        ]
    return [f"{ctor}({value})" for ctor in ctors]


def maude_num_alternatives(typ: str, value: str | None) -> list[str] | None:
    if typ in REF_HEAPTYPES:
        return maude_ref_alternatives(typ, value)
    if value is None:
        return None
    source_typ = WAST_NUM_TYPES.get(typ)
    if source_typ is not None:
        if typ in {"f32", "f64"} and value.startswith("nan"):
            return [f"__EXPECT_{source_typ}_NAN__"]
        return [wrapped_num_const(source_typ, value)]
    if typ == "v128":
        if any(re.fullmatch(r"[+-]?\d+", lane) is None for lane in value.split()):
            return None
        alts = [f"VCONST__(V128, $v128lanes({value}))"]
        packed = packed_v128_lanes(value)
        if packed is not None:
            alts.append(f"VCONST__(V128, {packed})")
        return alts
    return None


def maude_arg_flags(typ: str, value: str) -> list[str] | None:
    if typ == "i32":
        return ["--arg-i32", str(signed_int(value, 32))]
    if typ == "i64":
        return ["--arg-i64", str(signed_int(value, 64))]
    if typ == "f32":
        return ["--arg-f32", f"bits:{int(value)}"]
    if typ == "f64":
        return ["--arg-f64", f"bits:{int(value)}"]
    if typ == "v128":
        return ["--arg-v128", str(value)]
    if typ in REF_ARG_FLAGS:
        if value == "null":
            return ["--arg-ref-null", typ]
        return [REF_ARG_FLAGS[typ], str(value)]
    return None


def prelude_arg_spec(typ: str, value: object) -> str | None:
    if typ == "i32":
        return f"i32={signed_int(str(value), 32)}"
    if typ == "i64":
        return f"i64={signed_int(str(value), 64)}"
    if typ == "f32":
        return f"f32=bits:{int(str(value))}"
    if typ == "f64":
        return f"f64=bits:{int(str(value))}"
    if typ == "v128":
        return f"v128={format_wast_value(value)}"
    if typ in REF_HEAPTYPES:
        return f"{typ}=null" if value == "null" else f"{typ}={value}"
    return None


def action_prelude_spec(action: dict, drop_count: int, wasm: Path, timeout: int) -> str | None:
    field = action.get("field")
    if not field:
        return None
    funcidx = function_export_index_from_wasm(wasm, field, timeout)
    target = f"@index={funcidx}" if funcidx is not None else field
    if "\x00" in target:
        return None
    arg_specs: list[str] = []
    for arg in action.get("args", []):
        spec = prelude_arg_spec(arg.get("type", ""), arg.get("value", "0"))
        if spec is None:
            return None
        arg_specs.append(spec)
    return f"{target};{','.join(arg_specs)};drop={drop_count}"


def action_args(action: dict) -> list[str] | None:
    args = action.get("args", [])
    out: list[str] = []
    for arg in args:
        flags = maude_arg_flags(arg.get("type", ""), str(arg.get("value", "0")))
        if flags is None:
            return None
        out.extend(flags)
    return out


def expected_terms(expected: list[dict]) -> str | None:
    if not expected:
        return "eps"
    alternatives: list[str] = [""]
    for item in expected:
        value = format_wast_value(item["value"]) if "value" in item else None
        terms = maude_num_alternatives(item.get("type", ""), value)
        if terms is None:
            return None
        alternatives = [
            (prefix + " " + term).strip()
            for prefix in alternatives
            for term in terms
        ]
    return " || ".join(alternatives)


def expected_terms_for_assert_return(cmd: dict) -> tuple[str | None, str]:
    if cmd.get("expected") is not None:
        expected = expected_terms(cmd.get("expected", []))
        reason = "" if expected is not None else "only numeric/ref expected results are supported"
        return expected, reason
    if cmd.get("either") is not None:
        alternatives: list[str] = []
        for item in cmd.get("either", []):
            items = item if isinstance(item, list) else [item]
            expected = expected_terms(items)
            if expected is None:
                return None, "only numeric/ref either expected results are supported"
            alternatives.extend(part.strip() for part in expected.split(" || ") if part.strip())
        if alternatives:
            return " || ".join(alternatives), ""
    return None, "wast2json omitted expected value"


def observed_result_arity(observed: str) -> int:
    observed = observed.strip()
    if not observed or observed == "eps":
        return 0
    return 1


def format_wast_value(value: object) -> str:
    if isinstance(value, list):
        return " ".join(str(item) for item in value)
    return str(value)


def run_wast_assert(
    cli: str,
    maude: str,
    wasm: Path,
    cmd: dict,
    timeout: int,
    name: str,
    path: Path,
    prelude_specs: list[str] | None = None,
    import_memory_specs: list[str] | None = None,
    memory_data_specs: list[str] | None = None,
    table_data_specs: list[str] | None = None,
    state_func_specs: list[str] | None = None,
    rewrite_limit: int = 10000,
    search_fallback: bool = False,
) -> Result:
    action = cmd.get("action", {})
    if action.get("type") != "invoke":
        return Result("spec-tests", name, str(path), "wast-assert", "UNSUPPORTED", "", "", "only invoke actions are supported")
    arg_flags = action_args(action)
    if arg_flags is None:
        return Result("spec-tests", name, str(path), "wast-assert", "UNSUPPORTED", "", "", "only numeric invoke args are supported")
    field = action.get("field")
    if not field:
        return Result("spec-tests", name, str(path), "wast-assert", "UNSUPPORTED", "", "", "missing invoke field")
    invoke_flags = invoke_flags_for_export(wasm, field, timeout)
    if invoke_flags is None:
        return Result("spec-tests", name, str(path), "wast-assert", "UNSUPPORTED", "", "", "cannot pass export name through argv")
    if cmd.get("type") == "assert_return":
        expected, expected_reason = expected_terms_for_assert_return(cmd)
        if expected is None:
            return Result(
                "spec-tests",
                name,
                str(path),
                "wast-assert-return",
                "UNSUPPORTED",
                "",
                "",
                expected_reason,
            )
    elif cmd.get("type") == "assert_trap":
        expected = "TRAP"
    else:
        return Result("spec-tests", name, str(path), "wast-assert", "UNSUPPORTED", "", "", f"unsupported assertion {cmd.get('type')}")
    prelude_args: list[str] = []
    for spec in prelude_specs or []:
        prelude_args.extend(["--prelude-call", spec])
    import_memory_args: list[str] = []
    for spec in import_memory_specs or []:
        import_memory_args.extend(["--import-memory", spec])
    memory_data_args: list[str] = []
    for spec in memory_data_specs or []:
        memory_data_args.extend(["--memory-data", spec])
    table_data_args: list[str] = []
    for spec in table_data_specs or []:
        table_data_args.extend(["--table-data", spec])
    state_func_args: list[str] = []
    for spec in state_func_specs or []:
        state_func_args.extend(["--state-func", spec])
    base_cmd = (
        cli_prefix(cli)
        + [
            "--maude",
            maude,
            "--unchecked-run",
            "--result-only",
            "--rewrite-limit",
            str(rewrite_limit),
        ]
        + invoke_flags
        + import_memory_args
        + memory_data_args
        + table_data_args
        + state_func_args
        + prelude_args
        + arg_flags
    )
    search_terms = [
        part.strip()
        for part in expected.split(" || ")
        if part.strip() and not part.strip().startswith("__EXPECT_")
    ]
    if search_terms:
        code, out = run(base_cmd + [str(wasm)], timeout)
        status, observed, reason = classify_step_output(code, out, expected)
        if status == "PASS":
            return Result(
                "spec-tests",
                name,
                str(path),
                "wast-" + cmd.get("type", "assert"),
                "PASS",
                expected,
                observed,
                reason,
                parse_status="GENERATED",
                validation_status="VALIDATED",
                instantiate_status="INSTANTIATED",
                step_status="STEPPED",
                result_status="PASS",
            )
        attempts: list[tuple[str, str, str]] = [(status, observed, reason)]
        if search_fallback:
            for term in search_terms:
                code, out = run(base_cmd + ["--search-expected", term, str(wasm)], timeout)
                status, observed, reason = classify_step_output(code, out, expected)
                if status == "PASS":
                    final_status = "PASS"
                    return Result(
                        "spec-tests",
                        name,
                        str(path),
                        "wast-" + cmd.get("type", "assert"),
                        final_status,
                        expected,
                        term,
                        reason,
                        parse_status="GENERATED",
                        validation_status="VALIDATED",
                        instantiate_status="INSTANTIATED",
                        step_status="STEPPED",
                        result_status=final_status,
                    )
                attempts.append((status, observed, reason))
        status, observed, reason = attempts[-1] if attempts else ("WRONG_RESULT", "", "expected result is not reachable")
    else:
        code, out = run(base_cmd + [str(wasm)], timeout)
        status, observed, reason = classify_step_output(code, out, expected)
    final_status = "PASS" if status == "PASS" else status
    return Result(
        "spec-tests",
        name,
        str(path),
        "wast-" + cmd.get("type", "assert"),
        final_status,
        expected,
        observed,
        reason,
        parse_status="GENERATED" if final_status not in {"UNSUPPORTED", "WABT_FAIL", "FRONTEND_FAIL"} else "",
        validation_status="VALIDATED" if final_status in {"PASS", "WRONG_RESULT", "STEPPED"} else "",
        instantiate_status="INSTANTIATED" if final_status in {"PASS", "WRONG_RESULT", "STEPPED"} else "",
        step_status="STEPPED" if final_status in {"PASS", "WRONG_RESULT", "STEPPED"} else final_status,
        result_status=final_status,
    )


def run_wast_action(
    cli: str,
    maude: str,
    wasm: Path,
    action: dict,
    timeout: int,
    name: str,
    path: Path,
    prelude_specs: list[str] | None = None,
    import_memory_specs: list[str] | None = None,
    memory_data_specs: list[str] | None = None,
    table_data_specs: list[str] | None = None,
    state_func_specs: list[str] | None = None,
    rewrite_limit: int = 10000,
) -> Result:
    if action.get("type") != "invoke":
        return Result("spec-tests", name, str(path), "wast-action", "UNSUPPORTED", "", "", "only invoke actions are supported")
    arg_flags = action_args(action)
    if arg_flags is None:
        return Result("spec-tests", name, str(path), "wast-action", "UNSUPPORTED", "", "", "only numeric invoke args are supported")
    field = action.get("field")
    if not field:
        return Result("spec-tests", name, str(path), "wast-action", "UNSUPPORTED", "", "", "missing invoke field")
    invoke_flags = invoke_flags_for_export(wasm, field, timeout)
    if invoke_flags is None:
        return Result("spec-tests", name, str(path), "wast-action", "UNSUPPORTED", "", "", "cannot pass export name through argv")
    prelude_args: list[str] = []
    for spec in prelude_specs or []:
        prelude_args.extend(["--prelude-call", spec])
    import_memory_args: list[str] = []
    for spec in import_memory_specs or []:
        import_memory_args.extend(["--import-memory", spec])
    memory_data_args: list[str] = []
    for spec in memory_data_specs or []:
        memory_data_args.extend(["--memory-data", spec])
    table_data_args: list[str] = []
    for spec in table_data_specs or []:
        table_data_args.extend(["--table-data", spec])
    state_func_args: list[str] = []
    for spec in state_func_specs or []:
        state_func_args.extend(["--state-func", spec])
    code, out = run(
        cli_prefix(cli)
        + [
            "--maude",
            maude,
            "--unchecked-run",
            "--result-only",
            "--rewrite-limit",
            str(rewrite_limit),
        ]
        + invoke_flags
        + import_memory_args
        + memory_data_args
        + table_data_args
        + state_func_args
        + prelude_args
        + arg_flags
        + [str(wasm)],
        timeout,
    )
    step_status, observed, reason = classify_step_output(code, out)
    final_status = "PASS" if step_status == "STEPPED" else step_status
    return Result(
        "spec-tests",
        name,
        str(path),
        "wast-action",
        final_status,
        "",
        observed,
        reason,
        parse_status="GENERATED" if final_status not in {"UNSUPPORTED", "WABT_FAIL", "FRONTEND_FAIL"} else "",
        validation_status="VALIDATED" if final_status in {"PASS", "WRONG_RESULT", "STEPPED"} else "",
        instantiate_status="INSTANTIATED" if final_status in {"PASS", "WRONG_RESULT", "STEPPED"} else "",
        step_status=step_status,
        result_status=final_status,
    )


def run_wast_assert_invalid(
    cli: str,
    maude: str,
    wasm: Path,
    cmd: dict,
    timeout: int,
    name: str,
    path: Path,
) -> Result:
    del maude
    code, out = run(cli_prefix(cli) + ["--output", os.devnull, str(wasm)], timeout)
    status, observed, reason = classify_output(code, out)
    final_status = "PASS" if status in {"WABT_FAIL", "INVALID"} else "WRONG_RESULT"
    return Result(
        "spec-tests",
        name,
        str(path),
        "wast-assert-invalid",
        final_status,
        cmd.get("text", "invalid"),
        observed,
        reason if final_status == "PASS" else f"invalid assertion unexpectedly accepted: {status}",
        parse_status=status,
        validation_status="INVALID" if final_status == "PASS" else status,
        result_status=final_status,
    )


def run_wast_probe(
    cli: str,
    maude: str,
    path: Path,
    timeout: int,
    max_modules: int,
    max_asserts: int,
    rewrite_limit: int = 10000,
    search_fallback: bool = False,
) -> list[Result]:
    results: list[Result] = []
    if not shutil_which("wast2json") and not shutil_which("wasm-tools"):
        return [
            Result(
                "spec-tests",
                path.stem,
                str(path),
                "wast",
                "UNSUPPORTED",
                "",
                "",
                "neither wast2json nor wasm-tools is installed",
            )
        ]
    with tempfile.TemporaryDirectory(prefix="spec2maude-wast-") as tmpdir:
        out_json = Path(tmpdir) / "out.json"
        if shutil_which("wast2json"):
            code, out = run(
                ["wast2json", "--enable-all", str(path), "-o", str(out_json)],
                timeout,
            )
        else:
            code, out = (1, "wast2json is not installed")
        if code != 0 and shutil_which("wasm-tools"):
            code, out = run(
                [
                    "wasm-tools",
                    "json-from-wast",
                    str(path),
                    "-o",
                    str(out_json),
                    "--wasm-dir",
                    str(tmpdir),
                ],
                timeout,
            )
        if code != 0:
            status, observed, reason = classify_output(code, out)
            if status in {"FAIL", "FRONTEND_FAIL"}:
                status = "WABT_FAIL"
            return [
                Result("spec-tests", path.stem, str(path), "wast2json", status, "", observed, reason)
            ]
        try:
            data = json.loads(out_json.read_text())
        except Exception as exc:  # noqa: BLE001
            return [
                Result(
                    "spec-tests",
                    path.stem,
                    str(path),
                    "wast2json",
                    "FAIL",
                    "",
                    "",
                    f"cannot parse wast2json output: {exc}",
                )
            ]
        current_module_index = -1
        asserts = 0
        module_stage_count = 0
        module_files: list[Path] = []
        module_by_name: dict[str, Path] = {}
        register_by_name: dict[str, Path] = {}
        registered_memory_exports: dict[str, dict[str, MemoryExportState]] = {
            "spectest": {"memory": MemoryExportState(1, 2, {})}
        }
        memory_exports_by_wasm: dict[str, dict[str, MemoryExportState]] = {}
        registered_table_exports: dict[str, dict[str, TableExportState]] = {}
        table_exports_by_wasm: dict[str, dict[str, TableExportState]] = {}
        state_funcs: list[StateFunc] = []
        state_effects_cache: dict[str, dict] = {}
        prelude_by_module: dict[str, list[str]] = {}
        failed_prelude_by_module: dict[str, str] = {}

        def import_memory_specs() -> list[str]:
            return [
                format_import_memory_spec(module, name, state)
                for module, exports in registered_memory_exports.items()
                for name, state in exports.items()
            ]

        def memory_data_specs_for(wasm: Path) -> list[str]:
            specs: list[str] = []
            for name, state in memory_exports_by_wasm.get(str(wasm), {}).items():
                spec = format_memory_data_spec(name, state)
                if spec is not None:
                    specs.append(spec)
            return specs

        def table_data_specs_for(wasm: Path) -> list[str]:
            specs: list[str] = []
            for name, state in table_exports_by_wasm.get(str(wasm), {}).items():
                spec = format_table_data_spec(name, state)
                if spec is not None:
                    specs.append(spec)
            return specs

        def state_func_specs() -> list[str]:
            return [format_state_func_spec(func) for func in state_funcs]

        def state_cli_args_for(wasm: Path) -> list[str]:
            args: list[str] = []
            for spec in import_memory_specs():
                args.extend(["--import-memory", spec])
            for spec in memory_data_specs_for(wasm):
                args.extend(["--memory-data", spec])
            for spec in table_data_specs_for(wasm):
                args.extend(["--table-data", spec])
            for spec in state_func_specs():
                args.extend(["--state-func", spec])
            return args

        def effects_for(wasm: Path) -> dict:
            key = str(wasm)
            effects = state_effects_cache.get(key)
            if effects is None:
                effects = state_effects_from_wasm(cli, wasm, timeout)
                state_effects_cache[key] = effects
            return effects

        def action_may_mutate_state(wasm: Path, action: dict) -> bool:
            field = action.get("field")
            if not field:
                return True
            funcidx = function_export_index_from_wasm(wasm, field, timeout)
            if funcidx is None:
                return True
            effects = effects_for(wasm)
            funcs = {
                int(item["index"]): item
                for item in effects.get("funcs", [])
                if item.get("index") is not None
            }
            table_targets: set[int] | None = set()
            if effects.get("table_imports"):
                table_targets = None
            else:
                for segment in effects.get("active_elems", []):
                    for ref in segment.get("refs", []):
                        raw_index = ref.get("func_index")
                        if raw_index is None:
                            term = str(ref.get("term", ""))
                            if "REFNULL_" in term:
                                continue
                            table_targets = None
                            break
                        table_targets.add(int(raw_index))
                    if table_targets is None:
                        break

            mutation_cache: dict[int, bool] = {}
            visiting: set[int] = set()

            def body_may_mutate(index: int) -> bool:
                cached = mutation_cache.get(index)
                if cached is not None:
                    return cached
                if index in visiting:
                    return False
                visiting.add(index)
                body = str(funcs.get(index, {}).get("body", ""))
                result = True
                if body:
                    result = any(marker in body for marker in STATE_MUTATION_MARKERS)
                    if not result:
                        for match in DIRECT_CALL_RE.finditer(body):
                            if body_may_mutate(int(match.group(1))):
                                result = True
                                break
                    if not result and CALL_REF_RE.search(body):
                        static_targets = [
                            int(match.group(1))
                            for match in STATIC_REF_FUNC_CALL_RE.finditer(body)
                        ]
                        if len(static_targets) < len(CALL_REF_RE.findall(body)):
                            result = True
                        else:
                            for target in static_targets:
                                if body_may_mutate(target):
                                    result = True
                                    break
                    if not result and INDIRECT_CALL_RE.search(body):
                        if table_targets is None:
                            result = True
                        else:
                            for target in table_targets:
                                if body_may_mutate(target):
                                    result = True
                                    break
                visiting.remove(index)
                mutation_cache[index] = result
                return result

            return body_may_mutate(funcidx)

        def remember_registered_memory(alias: str, wasm: Path) -> None:
            exports = memory_exports_by_wasm.get(str(wasm))
            if exports is None:
                exports = memory_exports_from_wasm(wasm, timeout)
                memory_exports_by_wasm[str(wasm)] = exports
            registered_memory_exports[alias] = exports

        def remember_registered_table(alias: str, wasm: Path) -> None:
            exports = table_exports_by_wasm.get(str(wasm))
            if exports is None:
                effects = effects_for(wasm)
                exports = {
                    str(item.get("name")): TableExportState({})
                    for item in effects.get("table_exports", [])
                    if item.get("name") is not None
                }
                table_exports_by_wasm[str(wasm)] = exports
            registered_table_exports[alias] = exports

        def apply_active_data_to_registered_imports(wasm: Path) -> None:
            _, imports, _, active_data = wasm_memory_info(wasm, timeout)
            for segment in active_data:
                target = imports.get(segment.memory_index)
                if target is None:
                    continue
                module, name = target
                state = registered_memory_exports.get(module, {}).get(name)
                if state is not None:
                    if segment.offset + len(segment.bytes) > state.pages * 65536:
                        break
                    state.write(segment.offset, segment.bytes)

        def apply_active_elems_to_registered_imports(wasm: Path) -> None:
            effects = effects_for(wasm)
            table_imports = {
                int(item["index"]): (str(item["module"]), str(item["name"]))
                for item in effects.get("table_imports", [])
                if item.get("index") is not None
                and item.get("module") is not None
                and item.get("name") is not None
            }
            funcs = {
                int(item["index"]): item
                for item in effects.get("funcs", [])
                if item.get("index") is not None
            }
            func_addr_by_index: dict[int, int] = {}
            for elem in effects.get("active_elems", []):
                target = table_imports.get(int(elem.get("table", -1)))
                if target is None:
                    continue
                module, name = target
                state = registered_table_exports.get(module, {}).get(name)
                if state is None:
                    continue
                refs: list[str] = []
                for ref in elem.get("refs", []):
                    term = str(ref.get("term", ""))
                    func_index = ref.get("func_index")
                    if isinstance(func_index, int) and func_index in funcs:
                        addr = func_addr_by_index.get(func_index)
                        if addr is None:
                            func = funcs[func_index]
                            addr = len(state_funcs)
                            state_funcs.append(
                                StateFunc(
                                    str(func.get("type", "eps")),
                                    str(func.get("locals", "eps")),
                                    str(func.get("body", "eps")),
                                )
                            )
                            func_addr_by_index[func_index] = addr
                        refs.append(f"REFFUNCADDR_({addr})")
                    elif term:
                        refs.append(term)
                if refs:
                    state.write(int(elem.get("offset", 0)), refs)

        def registered_aliases_for_wasm(wasm: Path) -> list[str]:
            return [
                alias
                for alias, alias_wasm in register_by_name.items()
                if str(alias_wasm) == str(wasm)
            ]

        def memory_grow_delta(action: dict) -> int | None:
            field = str(action.get("field") or "").lower()
            if "grow" not in field:
                return None
            args = action.get("args", [])
            if args:
                try:
                    return int(str(args[0].get("value", "0")))
                except ValueError:
                    return None
            return 1

        def observed_i32_result(term: str) -> int | None:
            m = re.search(r"CONST__\(I32,\s*(\d+)\)", term)
            if not m:
                m = re.search(r"\bCONST\s+I32\s+(\d+)\b", term)
            if not m:
                return None
            value = int(m.group(1))
            if value == 0xFFFFFFFF:
                return None
            return value

        def remember_memory_growth(wasm: Path, action: dict, observed: str) -> None:
            delta = memory_grow_delta(action)
            old_size = observed_i32_result(observed)
            if delta is None or old_size is None or delta < 0:
                return
            exports = memory_exports_by_wasm.get(str(wasm))
            if exports is None:
                exports = memory_exports_from_wasm(wasm, timeout)
                memory_exports_by_wasm[str(wasm)] = exports
            if not exports:
                return
            new_size = old_size + delta
            for state in exports.values():
                if new_size > state.pages:
                    state.pages = new_size
            for alias in registered_aliases_for_wasm(wasm):
                registered_memory_exports[alias] = exports
        for cmd in data.get("commands", []):
            if cmd.get("type") == "module":
                current_module_index += 1
                filename = cmd.get("filename")
                wasm = Path(tmpdir) / filename if filename else Path("")
                module_files.append(wasm)
                if cmd.get("name"):
                    module_by_name[cmd["name"]] = wasm
                if wasm.exists():
                    if max_modules <= 0 or module_stage_count < max_modules:
                        import_kinds = wasm_import_kinds(wasm, timeout)
                        if "func" in import_kinds:
                            results.append(
                                Result(
                                    "spec-tests",
                                    f"{path.stem}:{current_module_index}",
                                    str(path),
                                    "wast-module-stage",
                                    "MODULE_STAGE",
                                    "",
                                    "",
                                    "module-stage has function imports; WAST action/assert path carries the stateful import environment",
                                    parse_status="GENERATED",
                                    validation_status="FRONTEND_VALIDATED",
                                    instantiate_status="DEFERRED",
                                    step_status="MODULE_STAGE",
                                    result_status="MODULE_STAGE",
                                )
                            )
                        else:
                            result = run_stage_probe(
                                cli,
                                maude,
                                wasm,
                                timeout,
                                suite="spec-tests",
                                mode="wast-module-stage",
                                rewrite_limit=rewrite_limit,
                                extra_cli_args=state_cli_args_for(wasm),
                            )
                            result.suite = "spec-tests"
                            result.name = f"{path.stem}:{current_module_index}"
                            result.path = str(path)
                            results.append(result)
                        module_stage_count += 1
                    apply_active_data_to_registered_imports(wasm)
                    apply_active_elems_to_registered_imports(wasm)
                continue
            if cmd.get("type") == "register":
                source = cmd.get("name")
                alias = cmd.get("as")
                if source and source in module_by_name and alias:
                    register_by_name[alias] = module_by_name[source]
                    remember_registered_memory(alias, module_by_name[source])
                    remember_registered_table(alias, module_by_name[source])
                elif current_module_index >= 0 and alias:
                    register_by_name[alias] = module_files[current_module_index]
                    remember_registered_memory(alias, module_files[current_module_index])
                    remember_registered_table(alias, module_files[current_module_index])
                continue
            if cmd.get("type") == "action":
                action = cmd.get("action", {})
                if action.get("type") != "invoke":
                    continue
                action_module = action.get("module")
                if action_module and action_module in module_by_name:
                    wasm = module_by_name[action_module]
                elif action_module and action_module in register_by_name:
                    wasm = register_by_name[action_module]
                elif current_module_index < 0 or current_module_index >= len(module_files):
                    continue
                else:
                    wasm = module_files[current_module_index]
                wasm_key = str(wasm)
                action_result = run_wast_action(
                    cli,
                    maude,
                    wasm,
                    action,
                    timeout,
                    f"{path.stem}:action:line{cmd.get('line', '')}",
                    path,
                    prelude_by_module.get(wasm_key, []),
                    import_memory_specs(),
                    memory_data_specs_for(wasm),
                    table_data_specs_for(wasm),
                    state_func_specs(),
                    rewrite_limit=rewrite_limit,
                )
                results.append(action_result)
                if action_result.status == "PASS":
                    remember_memory_growth(wasm, action, action_result.observed)
                    if action_may_mutate_state(wasm, action):
                        spec = action_prelude_spec(
                            action, observed_result_arity(action_result.observed), wasm, timeout
                        )
                        if spec is not None:
                            prelude_by_module.setdefault(wasm_key, []).append(spec)
                    failed_prelude_by_module.pop(wasm_key, None)
                else:
                    failed_prelude_by_module[wasm_key] = action_result.name
                continue
            if cmd.get("type") == "assert_invalid":
                if max_asserts > 0 and asserts >= max_asserts:
                    break
                filename = cmd.get("filename")
                if not filename:
                    continue
                wasm = Path(tmpdir) / filename
                if not wasm.exists():
                    continue
                results.append(
                    run_wast_assert_invalid(
                        cli,
                        maude,
                        wasm,
                        cmd,
                        timeout,
                        f"{path.stem}:assert-invalid:{asserts}:line{cmd.get('line', '')}",
                        path,
                    )
                )
                asserts += 1
                continue
            if cmd.get("type") == "assert_uninstantiable":
                filename = cmd.get("filename")
                if filename:
                    wasm = Path(tmpdir) / filename
                    if wasm.exists():
                        apply_active_data_to_registered_imports(wasm)
                        apply_active_elems_to_registered_imports(wasm)
                continue
            if cmd.get("type") not in {"assert_return", "assert_trap"}:
                continue
            if max_asserts > 0 and asserts >= max_asserts:
                break
            action = cmd.get("action", {})
            action_module = action.get("module")
            if action_module and action_module in module_by_name:
                wasm = module_by_name[action_module]
            elif action_module and action_module in register_by_name:
                wasm = register_by_name[action_module]
            elif current_module_index < 0 or current_module_index >= len(module_files):
                continue
            else:
                wasm = module_files[current_module_index]
            if not wasm.exists():
                continue
            wasm_key = str(wasm)
            failed_prelude = failed_prelude_by_module.get(wasm_key)
            if failed_prelude is not None:
                expected, _expected_reason = expected_terms_for_assert_return(cmd)
                results.append(
                    Result(
                        "spec-tests",
                        f"{path.stem}:assert:{asserts}:line{cmd.get('line', '')}",
                        str(path),
                        "wast-assert",
                        "STUCK_STEP",
                        expected or "",
                        "",
                        f"previous stateful action did not finish: {failed_prelude}",
                        "PARSED",
                        "VALIDATED",
                        "INSTANTIATED",
                        "STUCK_STEP",
                        "",
                    )
                )
                asserts += 1
                continue
            result = run_wast_assert(
                cli,
                maude,
                wasm,
                cmd,
                timeout,
                f"{path.stem}:assert:{asserts}:line{cmd.get('line', '')}",
                path,
                prelude_by_module.get(wasm_key, []),
                import_memory_specs(),
                memory_data_specs_for(wasm),
                table_data_specs_for(wasm),
                state_func_specs(),
                rewrite_limit=rewrite_limit,
                search_fallback=search_fallback,
            )
            results.append(result)
            if cmd.get("type") == "assert_return" and result.status == "PASS":
                remember_memory_growth(wasm, action, result.observed)
                if action_may_mutate_state(wasm, action):
                    spec = action_prelude_spec(
                        action,
                        observed_result_arity(result.observed),
                        wasm,
                        timeout,
                    )
                    if spec is not None:
                        prelude_by_module.setdefault(wasm_key, []).append(spec)
            asserts += 1
    return results


def shutil_which(tool: str) -> bool:
    return subprocess.run(
        ["sh", "-c", f"command -v {tool} >/dev/null 2>&1"], check=False
    ).returncode == 0


def write_csv(path: Path, rows: list[Result]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(
            [
                "suite",
                "name",
                "path",
                "mode",
                "status",
                "parse_status",
                "validation_status",
                "instantiate_status",
                "step_status",
                "result_status",
                "failure_category",
                "expected",
                "observed",
                "reason",
            ]
        )
        for r in rows:
            writer.writerow(
                [
                    r.suite,
                    r.name,
                    r.path,
                    r.mode,
                    r.status,
                    r.parse_status,
                    r.validation_status,
                    r.instantiate_status,
                    r.step_status,
                    r.result_status,
                    failure_category(r),
                    r.expected,
                    r.observed,
                    r.reason,
                ]
            )


def write_feature_reports(artifact_dir: Path, rows: list[Result]) -> None:
    artifact_dir.mkdir(parents=True, exist_ok=True)
    feature_counts: dict[str, Counter[str]] = defaultdict(Counter)
    category_counts: dict[str, Counter[str]] = defaultdict(Counter)
    file_counts: dict[tuple[str, str, str], Counter[str]] = defaultdict(Counter)
    for row in rows:
        feature = feature_of_path(row.path)
        feature_counts[feature][row.status] += 1
        category = failure_category(row)
        if category:
            category_counts[feature][category] += 1
        file_counts[(feature, row.path, row.mode)][row.status] += 1

    with (artifact_dir / "feature_summary.csv").open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["feature", "status", "count"])
        for feature in sorted(feature_counts):
            for status, count in sorted(feature_counts[feature].items()):
                writer.writerow([feature, status, count])

    with (artifact_dir / "file_status_summary.csv").open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["feature", "path", "mode", "status", "count"])
        for (feature, path, mode), counts in sorted(file_counts.items()):
            for status, count in sorted(counts.items()):
                writer.writerow([feature, path, mode, status, count])

    with (artifact_dir / "failure_category_summary.csv").open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["feature", "failure_category", "count"])
        for feature in sorted(category_counts):
            for category, count in sorted(category_counts[feature].items()):
                writer.writerow([feature, category, count])

    with (artifact_dir / "problem_cases.csv").open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(
            [
                "feature",
                "suite",
                "name",
                "path",
                "mode",
                "status",
                "step_status",
                "failure_category",
                "expected",
                "observed",
                "reason",
            ]
        )
        for row in rows:
            if row.status not in PROBLEM_STATUSES:
                continue
            writer.writerow(
                [
                    feature_of_path(row.path),
                    row.suite,
                    row.name,
                    row.path,
                    row.mode,
                    row.status,
                    row.step_status,
                    failure_category(row),
                    row.expected,
                    row.observed,
                    row.reason,
                ]
            )


def write_reports(artifact_dir: Path, rows: list[Result]) -> None:
    write_csv(artifact_dir / "benchmark_results.csv", rows)
    write_feature_reports(artifact_dir, rows)


def print_summary(rows: list[Result]) -> None:
    counts: dict[str, int] = {}
    for r in rows:
        counts[r.status] = counts.get(r.status, 0) + 1
    print("Benchmark summary:")
    for status in sorted(counts):
        print(f"  {status}: {counts[status]}")
    feature_counts: dict[str, Counter[str]] = defaultdict(Counter)
    category_counts: dict[str, Counter[str]] = defaultdict(Counter)
    for row in rows:
        feature_counts[feature_of_path(row.path)][row.status] += 1
        category = failure_category(row)
        if category:
            category_counts[feature_of_path(row.path)][category] += 1
    if feature_counts:
        print("Feature problem summary:")
        for feature in sorted(feature_counts):
            problems = {
                status: count
                for status, count in feature_counts[feature].items()
                if status in PROBLEM_STATUSES
            }
            if not problems:
                continue
            rendered = ", ".join(
                f"{status}: {count}" for status, count in sorted(problems.items())
            )
            print(f"  {feature}: {rendered}")
    if category_counts:
        print("Failure category summary:")
        for feature in sorted(category_counts):
            rendered = ", ".join(
                f"{category}: {count}"
                for category, count in sorted(category_counts[feature].items())
            )
            print(f"  {feature}: {rendered}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", default="_build/default/wasm_to_maude.exe")
    parser.add_argument("--maude", default=os.environ.get("MAUDE_BIN", "maude"))
    parser.add_argument("--timeout", type=int, default=10)
    parser.add_argument("--artifact-dir", default="artifacts/wasm-benchmark-latest")
    parser.add_argument(
        "--external-root",
        action="append",
        default=None,
        help="benchmark root to scan; may be repeated; defaults to benchmarks",
    )
    parser.add_argument(
        "--max-external-files",
        type=int,
        default=0,
        help="maximum external benchmark files to probe; 0 means no limit",
    )
    parser.add_argument(
        "--max-file-bytes",
        type=int,
        default=0,
        help="skip external .wat/.wasm files larger than this; 0 means no size limit",
    )
    parser.add_argument("--max-wast-modules", type=int, default=20)
    parser.add_argument("--max-wast-asserts", type=int, default=40)
    parser.add_argument(
        "--rewrite-limit",
        type=int,
        default=1000000,
        help="Maude rewrite bound for runtime assertions",
    )
    parser.add_argument(
        "--search-fallback",
        action="store_true",
        help="after deterministic rewrite misses an expected term, try Maude search",
    )
    parser.add_argument("--skip-smokes", action="store_true")
    parser.add_argument("--skip-external", action="store_true")
    parser.add_argument("--fail-on-external-failure", action="store_true")
    args = parser.parse_args()

    rows: list[Result] = []
    artifact_dir = ROOT / args.artifact_dir

    def flush_reports() -> None:
        write_reports(artifact_dir, rows)

    if not args.skip_smokes:
        rows.extend(run_smokes(args.cli, args.maude, args.timeout))
        rows.extend(run_invalid_smokes(args.cli, args.maude, args.timeout))
        flush_reports()

    external_files: list[Path] = []
    if not args.skip_external:
        external_root_args = args.external_root if args.external_root is not None else ["benchmarks"]
        roots = [ROOT / p for p in external_root_args]
        external_files = discover_bench_files(roots)
    if args.max_external_files > 0:
        external_files = external_files[: args.max_external_files]
    total_external = len(external_files)
    for index, path in enumerate(external_files, start=1):
        rel_for_progress = str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path)
        print(
            f"[{index}/{total_external}] {rel_for_progress}",
            file=sys.stderr,
            flush=True,
        )
        if args.max_file_bytes > 0 and path.suffix in {".wat", ".wasm"}:
            try:
                size = path.stat().st_size
            except OSError:
                size = 0
            if size > args.max_file_bytes:
                rows.append(
                    Result(
                        "external",
                        path.stem,
                        str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path),
                        "generate",
                        "SKIPPED_TOO_LARGE",
                        "",
                        "",
                        f"{size} bytes > {args.max_file_bytes}",
                    )
                )
                flush_reports()
                continue
        if "wat_examples" in path.parts:
            # Local examples are already run by the frontend/runtime smoke suite.
            continue
        if path.suffix == ".wast":
            rows.extend(
                run_wast_probe(
                    args.cli,
                    args.maude,
                    path,
                    args.timeout,
                    args.max_wast_modules,
                    args.max_wast_asserts,
                    args.rewrite_limit,
                    args.search_fallback,
                )
            )
        else:
            rows.append(
                run_stage_probe(
                    args.cli,
                    args.maude,
                    path,
                    args.timeout,
                    rewrite_limit=args.rewrite_limit,
                )
            )
        flush_reports()

    flush_reports()
    print_summary(rows)
    print(f"CSV: {artifact_dir / 'benchmark_results.csv'}")
    print(f"Feature summary: {artifact_dir / 'feature_summary.csv'}")
    print(f"Problem cases: {artifact_dir / 'problem_cases.csv'}")

    smoke_failed = any(r.suite == "wat_examples" and r.status != "PASS" for r in rows)
    invalid_failed = any(r.suite == "wat_examples_invalid" and r.status != "PASS" for r in rows)
    external_failed = any(
        r.suite != "wat_examples" and r.status in {"FAIL", "FRONTEND_FAIL", "WRONG_RESULT", "TIMEOUT"}
        for r in rows
    )
    if smoke_failed or invalid_failed or (args.fail_on_external_failure and external_failed):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
