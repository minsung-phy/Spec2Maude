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
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RAW_NUM_CONST_RE = re.compile(r"CTORCONSTA2\(CTOR(I32|I64|F32|F64)A0,\s*([+-]?\d+)\)")
NUM_CONST_SHAPES = {
    "I32": ("CTORI32A0", "litU32", 32),
    "I64": ("CTORI64A0", "litU64", 64),
    "F32": ("CTORF32A0", "litF32", None),
    "F64": ("CTORF64A0", "litF64", None),
}
WAST_NUM_TYPES = {
    "i32": "I32",
    "i64": "I64",
    "f32": "F32",
    "f64": "F64",
}


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
    ctor, wrapper, bits = shape
    payload = unsigned_payload(value, bits) if bits is not None else int(value)
    return f"CTORCONSTA2({ctor}, {wrapper}({payload}))"


def wrapped_numeric_equivalent(term: str) -> str:
    return RAW_NUM_CONST_RE.sub(
        lambda match: wrapped_num_const(match.group(1), match.group(2)),
        term,
    )


def expected_alternatives(expected: str) -> list[str]:
    """Accept current wrapped expectations plus old raw numeric fixtures."""
    alternatives: list[str] = []
    for item in (part.strip() for part in expected.split(" || ")):
        if not item:
            continue
        alternatives.append(item)
        wrapped = wrapped_numeric_equivalent(item)
        if wrapped != item:
            alternatives.append(wrapped)
    return alternatives


def memory_exports_from_wasm(wasm: Path, timeout: int) -> dict[str, tuple[int, int | None]]:
    code, out = run(["wasm2wat", "--enable-all", str(wasm)], timeout)
    if code != 0:
        return {}
    memory_pages: dict[int, tuple[int, int | None]] = {}
    exports: dict[str, tuple[int, int | None]] = {}
    for line in out.splitlines():
        line = line.strip()
        m = re.match(r'^\(memory\s+\(;(\d+);\)\s+(\d+)(?:\s+(\d+))?', line)
        if m:
            memory_pages[int(m.group(1))] = (
                int(m.group(2)),
                int(m.group(3)) if m.group(3) is not None else None,
            )
            continue
        m = re.match(r'^\(export\s+"([^"]+)"\s+\(memory\s+(\d+)\)\)', line)
        if m:
            idx = int(m.group(2))
            if idx in memory_pages:
                exports[m.group(1)] = memory_pages[idx]
    return exports


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
        if any(
            admin in observed
            for admin in [
                "CTORFRAMELBRACERBRACEA3",
                "CTORLABELLBRACERBRACEA3",
                "CTORCALLREFA1",
                "CTORCALLINDIRECTA2",
                "CTORRETURN_CALLA1",
            ]
        ):
            return ("STUCK_STEP", observed, "administrative/runtime term remains")
        if any(item in compact for item in expected_alternatives(expected)):
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


def smoke_cases() -> list[tuple[str, list[str], str]]:
    return [
        (
            "fib",
            ["--unchecked-run", "--result-only", "--run", "5", "wat_examples/fib.wat"],
            "CTORCONSTA2(CTORI32A0, litU32(5))",
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
            "CTORCONSTA2(CTORI32A0, litU32(5))",
        ),
        (
            "global-get",
            ["--unchecked-run", "--result-only", "--run-main", "wat_examples/global-get.wat"],
            "CTORCONSTA2(CTORI32A0, litU32(42))",
        ),
        (
            "memory-size",
            ["--unchecked-run", "--result-only", "--run-main", "wat_examples/memory-size.wat"],
            "CTORCONSTA2(CTORI32A0, litU32(0))",
        ),
        (
            "table-size",
            ["--unchecked-run", "--result-only", "--run-main", "wat_examples/table-size.wat"],
            "CTORCONSTA2(CTORI32A0, litU32(3))",
        ),
        (
            "start-global",
            ["--unchecked-run", "--result-only", "--run-main", "wat_examples/start-global.wat"],
            "CTORCONSTA2(CTORI32A0, litU32(7))",
        ),
        (
            "data-load",
            ["--unchecked-run", "--result-only", "--run-main", "wat_examples/data-load.wat"],
            "CTORCONSTA2(CTORI32A0, litU32(42))",
        ),
        (
            "elem-call-ref",
            ["--unchecked-run", "--result-only", "--run-main", "wat_examples/elem-call-ref.wat"],
            "CTORCONSTA2(CTORI32A0, litU32(9))",
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
            "CTORCONSTA2(CTORI32A0, litU32(42))",
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
            "CTORCONSTA2(CTORI32A0, litU32(77))",
        ),
        (
            "import-memory",
            ["--unchecked-run", "--result-only", "--run-export", "main", "wat_examples/import-memory.wat"],
            "CTORCONSTA2(CTORI32A0, litU32(1))",
        ),
        (
            "import-table",
            ["--unchecked-run", "--result-only", "--run-export", "main", "wat_examples/import-table.wat"],
            "CTORCONSTA2(CTORI32A0, litU32(4))",
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
    if "steps(" in compact or "result Config:" in out or "CTORTRAPA0" in compact:
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


def run_generate(cli: str, path: Path, timeout: int, out_path: Path) -> tuple[str, str, str]:
    code, out = run(cli_prefix(cli) + ["--output", str(out_path), str(path)], timeout)
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
) -> Result:
    rel = str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path)
    with tempfile.TemporaryDirectory(prefix="spec2maude-stage-") as tmpdir:
        generated = Path(tmpdir) / "generated.maude"
        gen_status, gen_observed, gen_reason = run_generate(cli, path, timeout, generated)
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
        step_status, step_observed, step_reason = run_step_stage(
            cli, maude, path, timeout, rewrite_limit=rewrite_limit
        )
        final_status = step_status if step_status != "STEPPED" else "STEPPED"
        return Result(
            suite,
            path.stem,
            rel,
            mode,
            final_status,
            "",
            step_observed,
            step_reason,
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


REF_HEAPTYPES = {
    "funcref": "CTORFUNCA0",
    "externref": "CTOREXTERNA0",
    "anyref": "CTORANYA0",
    "eqref": "CTORWEQA0",
    "i31ref": "CTORI31A0",
    "structref": "CTORSTRUCTA0",
    "arrayref": "CTORARRAYA0",
    "exnref": "CTOREXNA0",
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
    "funcref": ["CTORREFFUNCADDRA1"],
    "externref": ["CTORREFEXTERNA1"],
    "anyref": [
        "CTORREFHOSTADDRA1",
        "CTORREFEXTERNA1",
        "CTORREFFUNCADDRA1",
        "CTORREFI31NUMA1",
        "CTORREFSTRUCTADDRA1",
        "CTORREFARRAYADDRA1",
    ],
    "eqref": ["CTORREFI31NUMA1", "CTORREFSTRUCTADDRA1", "CTORREFARRAYADDRA1"],
    "i31ref": ["CTORREFI31NUMA1"],
    "structref": ["CTORREFSTRUCTADDRA1"],
    "arrayref": ["CTORREFARRAYADDRA1"],
    "exnref": ["CTORREFEXNADDRA1"],
}


def maude_ref_alternatives(typ: str, value: str | None) -> list[str] | None:
    heap = REF_HEAPTYPES.get(typ)
    ctors = REF_VALUE_CTORS.get(typ)
    if heap is None or ctors is None:
        return None
    if value == "null":
        return [f"CTORREFNULLA1({heap})"]
    if value is None:
        return [f"{ctor}(" for ctor in ctors]
    if typ == "externref":
        return [
            f"CTORREFEXTERNA1({value})",
            f"CTORREFEXTERNA1(CTORREFHOSTADDRA1({value}))",
        ]
    return [f"{ctor}({value})" for ctor in ctors]


def maude_num_alternatives(typ: str, value: str | None) -> list[str] | None:
    if typ in REF_HEAPTYPES:
        return maude_ref_alternatives(typ, value)
    if value is None:
        return None
    source_typ = WAST_NUM_TYPES.get(typ)
    if source_typ is not None:
        return [wrapped_num_const(source_typ, value)]
    if typ == "v128":
        return [f"CTORVCONSTA2(CTORV128A0, $v128lanes({value}))"]
    return None


def maude_arg_flags(typ: str, value: str) -> list[str] | None:
    if typ == "i32":
        return ["--arg-i32", str(signed_int(value, 32))]
    if typ == "i64":
        return ["--arg-i64", str(signed_int(value, 64))]
    if typ == "f32":
        return ["--arg-f32", str(int(value))]
    if typ == "f64":
        return ["--arg-f64", str(int(value))]
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
        return f"f32={int(str(value))}"
    if typ == "f64":
        return f"f64={int(str(value))}"
    if typ == "v128":
        return f"v128={format_wast_value(value)}"
    if typ in REF_HEAPTYPES:
        return f"{typ}=null" if value == "null" else f"{typ}={value}"
    return None


def action_prelude_spec(action: dict, drop_count: int) -> str | None:
    field = action.get("field")
    if not field:
        return None
    arg_specs: list[str] = []
    for arg in action.get("args", []):
        spec = prelude_arg_spec(arg.get("type", ""), arg.get("value", "0"))
        if spec is None:
            return None
        arg_specs.append(spec)
    return f"{field};{','.join(arg_specs)};drop={drop_count}"


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
    rewrite_limit: int = 10000,
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
    if cmd.get("type") == "assert_return":
        if cmd.get("expected") is None:
            return Result(
                "spec-tests",
                name,
                str(path),
                "wast-assert-return",
                "UNSUPPORTED",
                "",
                "",
                "wast2json omitted expected value, usually for nondeterministic/either assertion",
            )
        expected = expected_terms(cmd.get("expected", []))
        if expected is None:
            return Result("spec-tests", name, str(path), "wast-assert-return", "UNSUPPORTED", "", "", "only numeric/ref expected results are supported")
    elif cmd.get("type") == "assert_trap":
        expected = "CTORTRAPA0"
    else:
        return Result("spec-tests", name, str(path), "wast-assert", "UNSUPPORTED", "", "", f"unsupported assertion {cmd.get('type')}")
    prelude_args: list[str] = []
    for spec in prelude_specs or []:
        prelude_args.extend(["--prelude-call", spec])
    import_memory_args: list[str] = []
    for spec in import_memory_specs or []:
        import_memory_args.extend(["--import-memory", spec])
    code, out = run(
        cli_prefix(cli)
        + [
            "--maude",
            maude,
            "--unchecked-run",
            "--result-only",
            "--rewrite-limit",
            str(rewrite_limit),
            "--run-export",
            field,
        ]
        + import_memory_args
        + prelude_args
        + arg_flags
        + [str(wasm)],
        timeout,
    )
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
    prelude_args: list[str] = []
    for spec in prelude_specs or []:
        prelude_args.extend(["--prelude-call", spec])
    import_memory_args: list[str] = []
    for spec in import_memory_specs or []:
        import_memory_args.extend(["--import-memory", spec])
    code, out = run(
        cli_prefix(cli)
        + [
            "--maude",
            maude,
            "--unchecked-run",
            "--result-only",
            "--rewrite-limit",
            str(rewrite_limit),
            "--run-export",
            field,
        ]
        + import_memory_args
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
        count = 0
        for cmd in data.get("commands", []):
            if count >= max_modules:
                break
            if cmd.get("type") != "module":
                continue
            filename = cmd.get("filename")
            if not filename:
                continue
            wasm = Path(tmpdir) / filename
            result = run_stage_probe(
                cli,
                maude,
                wasm,
                timeout,
                suite="spec-tests",
                mode="wast-module-stage",
                rewrite_limit=rewrite_limit,
            )
            result.suite = "spec-tests"
            result.name = f"{path.stem}:{count}"
            result.path = str(path)
            results.append(result)
            count += 1
        current_module_index = -1
        asserts = 0
        module_files: list[Path] = []
        module_by_name: dict[str, Path] = {}
        register_by_name: dict[str, Path] = {}
        registered_memory_exports: dict[str, dict[str, tuple[int, int | None]]] = {}
        prelude_by_module: dict[str, list[str]] = {}
        failed_prelude_by_module: dict[str, str] = {}
        for cmd in data.get("commands", []):
            if cmd.get("type") == "module":
                current_module_index += 1
                filename = cmd.get("filename")
                wasm = Path(tmpdir) / filename if filename else Path("")
                module_files.append(wasm)
                if cmd.get("name"):
                    module_by_name[cmd["name"]] = wasm
                continue
            if cmd.get("type") == "register":
                source = cmd.get("name")
                alias = cmd.get("as")
                if source and source in module_by_name and alias:
                    register_by_name[alias] = module_by_name[source]
                    registered_memory_exports[alias] = memory_exports_from_wasm(
                        module_by_name[source], timeout
                    )
                elif current_module_index >= 0 and alias:
                    register_by_name[alias] = module_files[current_module_index]
                    registered_memory_exports[alias] = memory_exports_from_wasm(
                        module_files[current_module_index], timeout
                    )
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
                    [
                        f"{module}.{name}={pages}"
                        + (f"/{max_pages}" if max_pages is not None else "")
                        for module, exports in registered_memory_exports.items()
                        for name, (pages, max_pages) in exports.items()
                    ],
                    rewrite_limit=rewrite_limit,
                )
                results.append(action_result)
                if action_result.status == "PASS":
                    spec = action_prelude_spec(
                        action, observed_result_arity(action_result.observed)
                    )
                    if spec is not None:
                        prelude_by_module.setdefault(wasm_key, []).append(spec)
                    failed_prelude_by_module.pop(wasm_key, None)
                else:
                    failed_prelude_by_module[wasm_key] = action_result.name
                continue
            if cmd.get("type") == "assert_invalid":
                if asserts >= max_asserts:
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
            if cmd.get("type") not in {"assert_return", "assert_trap"}:
                continue
            if asserts >= max_asserts:
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
                results.append(
                    Result(
                        "spec-tests",
                        f"{path.stem}:assert:{asserts}:line{cmd.get('line', '')}",
                        str(path),
                        "wast-assert",
                        "STUCK_STEP",
                        expected_terms(cmd.get("expected", [])) or "",
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
                [
                    f"{module}.{name}={pages}" + (f"/{max_pages}" if max_pages is not None else "")
                    for module, exports in registered_memory_exports.items()
                    for name, (pages, max_pages) in exports.items()
                ],
                rewrite_limit=rewrite_limit,
            )
            results.append(result)
            if cmd.get("type") == "assert_return" and result.status == "PASS":
                spec = action_prelude_spec(action, len(cmd.get("expected", [])))
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
                    r.expected,
                    r.observed,
                    r.reason,
                ]
            )


def print_summary(rows: list[Result]) -> None:
    counts: dict[str, int] = {}
    for r in rows:
        counts[r.status] = counts.get(r.status, 0) + 1
    print("Benchmark summary:")
    for status in sorted(counts):
        print(f"  {status}: {counts[status]}")


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
        default=10000,
        help="Maude rewrite bound for runtime assertions",
    )
    parser.add_argument("--skip-smokes", action="store_true")
    parser.add_argument("--skip-external", action="store_true")
    parser.add_argument("--fail-on-external-failure", action="store_true")
    args = parser.parse_args()

    rows: list[Result] = []
    if not args.skip_smokes:
        rows.extend(run_smokes(args.cli, args.maude, args.timeout))
        rows.extend(run_invalid_smokes(args.cli, args.maude, args.timeout))

    external_files: list[Path] = []
    if not args.skip_external:
        external_root_args = args.external_root if args.external_root is not None else ["benchmarks"]
        roots = [ROOT / p for p in external_root_args]
        external_files = discover_bench_files(roots)
    if args.max_external_files > 0:
        external_files = external_files[: args.max_external_files]
    for path in external_files:
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

    artifact_dir = ROOT / args.artifact_dir
    write_csv(artifact_dir / "benchmark_results.csv", rows)
    print_summary(rows)
    print(f"CSV: {artifact_dir / 'benchmark_results.csv'}")

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
