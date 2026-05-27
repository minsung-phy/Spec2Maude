<h1 align="center">Spec2Maude</h1>

<p align="center">
  <strong>A research prototype for translating SpecTec language definitions into executable Maude specifications.</strong>
</p>

---

## What This Project Does

Spec2Maude translates language definitions written in **SpecTec** into
**Maude** rewriting-logic specifications.

The current main case study is **WebAssembly 3.0**.  The project has two
connected goals:

1. Translate the WebAssembly SpecTec source into a Maude specification while
   preserving the source structure as much as possible.
2. Run concrete `.wat` / `.wasm` programs by generating a Maude module term,
   validating it with the translated WebAssembly validation rules, instantiating
   it, and executing it with Maude rewriting.

The current execution pipeline is:

```text
.wat / .wasm
  -> WAT/Wasm frontend
  -> Maude module term
  -> Module-ok validation
  -> $instantiate
  -> invoke / call_ref
  -> steps
  -> result comparison
```

This is a research artifact, not a production WebAssembly runtime.  The
important question is not only "can this program run?", but also "how close is
the generated Maude to the original SpecTec definition?".

## Current State

The active path is the **C1 WebAssembly baseline**:

- `translator_bs.ml` translates `wasm-3.0/*.spectec`.
- `output_bs.maude` is the generated WebAssembly Maude core.
- `wasm_to_maude.ml` converts `.wat` / `.wasm` inputs into generated Maude
  harnesses.
- `wasm-init-bs.maude` contains init/config/runtime harness code kept outside
  the generated core.
- `scripts/run_c1_regression.sh` runs the current local and benchmark
  regression.

Latest checked regression shape:

```text
total benchmark rows: 568
PASS: 319
STEPPED: 74
INVALID: 21
NO_ENTRY: 58
IMPORT_MISSING: 5
UNSUPPORTED: 4
STUCK_VALIDATION: 46
STUCK_STEP: 8
WRONG_RESULT: 33

Maude load warnings: 0
step-from-step-pure count: 0
```

How to read the important buckets:

- `PASS`: validation, instantiation, execution, and expected-result comparison
  succeeded.
- `STEPPED`: execution reached a final Maude config, but the benchmark did not
  provide an expected result to compare.
- `INVALID`: the input was rejected as invalid, or `Module-ok` did not prove it
  valid.
- `STUCK_VALIDATION`: Maude term generation succeeded, but `Module-ok` /
  validation did not finish as `valid`.
- `STUCK_STEP`: validation/init succeeded, but runtime `steps` got stuck or
  timed out.
- `WRONG_RESULT`: execution ended, but the result did not match the expected
  value.

See [STATUS.md](STATUS.md) for the current handoff state and
[docs/limitation.md](docs/limitation.md) for open research limitations.

## Repository Layout

```text
translator_bs.ml          active SpecTec-to-Maude translator
main_bs.ml                translator entry point
output_bs.maude           generated WebAssembly Maude core
builtins.maude            selected backend/builtin Maude definitions
wasm-init-bs.maude        init/config/runtime harness outside output_bs.maude
wasm-exec-bs.maude        concrete execution harness and smoke terms
wasm_to_maude.ml          .wat/.wasm frontend and execution CLI
wat_examples/             local smoke WAT programs
wasm-3.0/                 WebAssembly 3.0 SpecTec source files
scripts/                  regression, benchmark, and audit scripts
docs/HowToTest.md         detailed test commands
docs/limitation.md        current limitations and discussion points
STATUS.md                 current project status
```

Legacy files such as `translator.ml`, `output.maude`, and `wasm-exec.maude`
belong to older paths unless a document explicitly says otherwise.

## Requirements

You need:

- macOS or Linux shell environment
- OCaml / opam
- Dune
- Maude 3.5.1 or compatible
- WABT tools for `.wat` / `.wasm` handling

Install the common tools on macOS:

```bash
brew install opam dune wabt
```

Install Maude separately if it is not already available:

```bash
command -v maude
maude --version
```

This repository's regression script also looks for local Maude binaries at:

```text
/Users/minsung/Dev/tools/Maude-3.5.1-macos-x86_64/maude
```

If Maude is elsewhere, set:

```bash
export MAUDE_BIN=/path/to/maude
```

Check WABT:

```bash
command -v wasm2wat
command -v wat2wasm
command -v wasm-validate
command -v wast2json
```

## OCaml Setup

Create or select an opam switch:

```bash
opam switch create spec2maude 5.2.0
eval "$(opam env --switch=spec2maude)"
```

Install build dependencies:

```bash
opam install dune
```

If you already have a working switch, just run:

```bash
eval "$(opam env)"
```

Then build:

```bash
dune build ./main_bs.exe ./wasm_to_maude.exe
```

## Regenerate The Maude Core

Generate `output_bs.maude` from the WebAssembly SpecTec source:

```bash
dune exec ./main_bs.exe -- wasm-3.0/*.spectec > output_bs.maude
```

Load the execution harness:

```bash
maude wasm-exec-bs.maude
```

Expected load behavior:

```text
no Warning
no Advisory
no Error
```

## Run A Built-In Maude Smoke Test

Inside Maude:

```maude
rew [1] in WASM-FIB-BS : steps(fib-config(i32v(5))) .
```

Expected final value:

```maude
CTORCONSTA2(CTORI32A0, 5)
```

This checks the handwritten smoke config in `wasm-exec-bs.maude`.

## Run A WAT File

Run Fibonacci from `wat_examples/fib.wat`:

```bash
dune exec ./wasm_to_maude.exe -- --result-only --checked-run --run 5 wat_examples/fib.wat
```

Expected output:

```text
result: CTORCONSTA2(CTORI32A0, 5)
```

What happens here:

1. The frontend reads `fib.wat`.
2. WABT canonicalizes/validates the WAT.
3. The frontend creates a Maude module term.
4. The generated harness checks `Module-ok`.
5. It instantiates the module.
6. It invokes the function.
7. It runs `steps`.
8. It prints the final result.

Run other local examples:

```bash
dune exec ./wasm_to_maude.exe -- --result-only --checked-run --run-main wat_examples/global-get.wat
dune exec ./wasm_to_maude.exe -- --result-only --checked-run --run-main wat_examples/memory-size.wat
dune exec ./wasm_to_maude.exe -- --result-only --checked-run --run-main wat_examples/table-size.wat
dune exec ./wasm_to_maude.exe -- --result-only --checked-run --run-main wat_examples/start-global.wat
dune exec ./wasm_to_maude.exe -- --result-only --checked-run --run-main wat_examples/data-load.wat
dune exec ./wasm_to_maude.exe -- --result-only --checked-run --run-main wat_examples/elem-call-ref.wat
```

Run a `.wasm` file by converting a smoke input first:

```bash
wat2wasm --enable-all wat_examples/fib.wat -o /tmp/fib.wasm
dune exec ./wasm_to_maude.exe -- --result-only --checked-run --run 5 /tmp/fib.wasm
```

## Imports

WebAssembly modules may import functions, globals, memories, or tables from an
external environment.  If a module imports a function, the function body is not
inside the WAT/Wasm file, so the CLI needs an implementation.

Example:

```bash
dune exec ./wasm_to_maude.exe -- --result-only --checked-run \
  --run-export main \
  --arg-i32 41 \
  --import-func 'env.bump=local.get 0 i32.const 1 i32.add' \
  wat_examples/import-func.wat
```

Expected:

```text
result: CTORCONSTA2(CTORI32A0, 42)
```

Other import examples:

```bash
dune exec ./wasm_to_maude.exe -- --result-only --checked-run \
  --run-export main \
  --import-global 'env.g=i32.const 77' \
  wat_examples/import-global.wat

dune exec ./wasm_to_maude.exe -- --result-only --checked-run \
  --run-export main wat_examples/import-memory.wat

dune exec ./wasm_to_maude.exe -- --result-only --checked-run \
  --run-export main wat_examples/import-table.wat
```

## Invalid Input

Invalid programs must not execute.  The normal frontend path rejects invalid
WAT/Wasm before runtime, and the generated checked-run path also gates runtime
execution by `Module-ok`.

Example invalid input:

```bash
dune exec ./wasm_to_maude.exe -- --checked-run --result-only --run-main \
  wat_examples/invalid-result-type.wat
```

This module declares an `i32` result but returns an `i64`, so it should be
rejected.

## Full Regression

Run the current regression:

```bash
scripts/run_c1_regression.sh
```

The script:

1. checks WABT tools,
2. builds the translator and frontend,
3. regenerates `output_bs.maude`,
4. checks structural invariants,
5. runs local WAT/Wasm smokes,
6. probes benchmark/spec-test cases,
7. checks Maude load warnings,
8. writes artifacts under `artifacts/c1-regression-*`.

Fetch external benchmark repositories when needed:

```bash
scripts/fetch_wasm_benchmarks.sh
```

Run only the benchmark classifier:

```bash
scripts/run_wasm_benchmarks.py \
  --cli _build/default/wasm_to_maude.exe \
  --maude "${MAUDE_BIN:-maude}" \
  --timeout 5 \
  --max-external-files 80 \
  --max-file-bytes 1000000 \
  --artifact-dir artifacts/wasm-benchmark-latest
```

## Current Limitations

The frontend and runtime are not yet full WebAssembly 3.0 coverage.

Known remaining work:

- reduce `STUCK_VALIDATION` cases by improving `Module-ok` / `Instrs-ok`
  executability;
- reduce `STUCK_STEP` cases by filling runtime rule and builtin gaps;
- reduce `WRONG_RESULT` cases in memory, ref, import/linking, float, and SIMD
  families;
- support more proposal syntax and structured exception forms;
- keep non-source helper infrastructure out of `output_bs.maude` when possible;
- document any remaining source-derived helper as research infrastructure.

The current C1 core no longer has `step-from-step-pure-*` rules and no longer
uses `$is-spectec-val-seq`; source `val*` is represented with a `ValSeq` Maude
sort instead.

## Development Notes

`output_bs.maude` is generated.  Prefer editing `translator_bs.ml` and
regenerating instead of hand-editing `output_bs.maude`.

Before committing translation/runtime changes, run:

```bash
dune build ./main_bs.exe ./wasm_to_maude.exe
scripts/run_c1_regression.sh
```

For documentation-only changes, at least inspect the current status with:

```bash
git diff --stat
```
