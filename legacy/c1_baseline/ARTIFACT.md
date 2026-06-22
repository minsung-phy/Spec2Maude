# Spec2Maude Artifact Guide

Updated: 2026-06-11

This guide is the reviewer-facing checklist for the current Spec2Maude
artifact snapshot.

## Claimed Artifact Behavior

This artifact demonstrates that Spec2Maude can:

1. translate the WebAssembly 3.0 SpecTec source into Maude;
2. generate the carrier-based syntax layer:
   `SpectecTerminal`, `SpectecType`, `typecheck`, and `mb`/`cmb` membership;
3. keep source syntax constructors readable while disambiguating reused source
   heads from source category information, for example `func-func`,
   `func-externtype`, and `sub-subtype`;
4. load the generated Maude core without fatal parse/load diagnostics;
5. run local WAT/Wasm smoke programs through the official WebAssembly
   parser/validator frontend and Maude dynamic execution.

It does not claim full official WebAssembly test-suite conformance yet.

The WAT/Wasm frontend and benchmark runner use the same generated surface
syntax.  Runtime values are expected as source-readable prefix terms such as
`const(i32, 5)`, `ref-null(func-absheaptype)`, and `vconst(v128, ...)`, not the
old compact constructor spelling such as `CONST__` or `REFNULL_`.

## Requirements

Required:

```bash
command -v dune
command -v maude
command -v python3
```

Required OCaml packages:

```bash
opam install dune menhir
```

Optional, for official `.wast` slices:

```bash
command -v wast2json
```

## Quick Reproduction

From the repository root:

```bash
make build
./spec2maude translate -o output.maude
python3 scripts/audit_syntax_translation.py output.maude --source-dir wasm-3.0
python3 scripts/audit_translator_cleanup.py
maude -no-banner output.maude
maude -no-banner wasm-exec.maude
./spec2maude run wat_examples/fib.wat --fib 5
./spec2maude test smoke --timeout 10
```

Expected summary:

```text
Syntax audit: output.maude
PASS: no required syntax/typecheck/membership failures found

Translator cleanup audit
PASS: no forbidden cleanup regressions found

maude output.maude        warnings: 2, fatal diagnostics: 0
maude wasm-exec.maude     warnings: 2, fatal diagnostics: 0

result: const(i32, 5)

Benchmark summary:
  PASS: 13
```

The Maude warnings are parser ambiguity warnings. They should not include
`Error:`, `no parse`, `bad token`, `used before bound`, or `unpatchable`.

## What To Inspect In output.maude

The generated syntax carrier should include:

```bash
rg 'sort SpectecTerminal|sort SpectecType|op typecheck' output.maude
rg 'mb |cmb ' output.maude
rg 'op syn-(instr|func|i32) : -> SpectecType' output.maude
rg 'op (func-externidx|func-externtype|func-func|sub-binop|sub-subtype)' output.maude
```

The old category-sort encoding should not reappear:

```bash
rg 'SpectecCategory|WasmType|hasType|WellTyped|_hasType_|SortCTOR' output.maude
rg '^[[:space:]]+(sort|subsort).*\b(Instr|Valtype|U32|Typeuse)\b' output.maude
```

Expected: no matches for the old encoding checks.

Generated WAT/Wasm harnesses should likewise use the current prefix spelling:

```bash
dune exec ./wasm_to_maude.exe -- --output /tmp/fib.generated.maude wat_examples/fib.wat
rg 'const\(i32|func-func|local-get|binop|relop' /tmp/fib.generated.maude
rg 'CONST__|FUNC___|CALL_|WRESULT_|REFNULL_|VCONST__' /tmp/fib.generated.maude
```

Expected: matches for the first harness check and no matches for the second.

## Direct Maude Execution Check

Inside Maude:

```maude
rew [1] in WASM-FIB :
  steps(fib-config(i32v(5))) .
```

Expected final value:

```maude
const(i32, 5)
```

The surrounding store/frame term may be printed in full by Maude. The final
instruction result after the last top-level semicolon is the important part.

## Official Test-Suite Probe

For a small progress probe:

```bash
./spec2maude test official --limit 30 --timeout 5
```

Last recorded small official-slice reference bucket shape:

```text
Benchmark summary:
  INVALID: 10
  MODULE_STAGE: 40
  PASS: 43
  STUCK_INIT: 16
  STUCK_STEP: 69
  WRONG_RESULT: 3
```

This command is not the main pass/fail criterion for the artifact. It is a
regression/progress probe over a changing subset of the official `.wast`
corpus.

## Output Artifacts

Benchmark runs write reports under `artifacts/`, including:

```text
benchmark_results.csv
feature_summary.csv
file_status_summary.csv
failure_category_summary.csv
problem_cases.csv
```

The most useful files for debugging are `problem_cases.csv` and
`failure_category_summary.csv`.

## Known Limitations

- Remaining Maude warnings are parser-ambiguity warnings from the
  `norm(...)`/`subnorm(...)` float syntax equations.  Numeric `uN`/`sN` range
  guards are rendered in a source-readable form rather than Maude internal
  prefix operators such as `_<=_`.  The earlier nullary/unary constructor
  overload warning class is resolved by source-derived argument-shape suffixes
  such as `div-sx-binop` and `le-sx-relop`, and the old typed-index warning
  class is no longer present in generated output.
- The default WAT/Wasm execution path validates input with the official
  WebAssembly parser/validator before Maude execution.  The current runtime
  artifact does not use translated `Module-ok` as an execution gate.
- The full official WebAssembly suite still has `STUCK_INIT`, `STUCK_STEP`,
  and `WRONG_RESULT` cases, mainly from harness state, builtins, and proposal
  coverage gaps.

See `docs/HowToTest.md` for command details and `docs/limitation.md` for the
research limitations.
