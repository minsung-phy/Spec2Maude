# How To Test The Current C1 Baseline

Updated: 2026-05-27

This document contains reproducible commands for the active C1 path:

```text
translator_bs.ml
output_bs.maude
builtins.maude
wasm-init-bs.maude
wasm-exec-bs.maude
wasm_to_maude.ml
```

## 0. Tool Check

```bash
eval "$(opam env)"
dune --version
command -v maude || echo "set MAUDE_BIN=/path/to/maude"
command -v wasm2wat
command -v wat2wasm
command -v wasm-validate
command -v wast2json
```

If Maude is not on `PATH`, set:

```bash
export MAUDE_BIN=/path/to/maude
```

## 1. Build

```bash
dune build ./main_bs.exe ./wasm_to_maude.exe
```

## 2. Regenerate `output_bs.maude`

```bash
dune exec ./main_bs.exe -- wasm-3.0/*.spectec > output_bs.maude
```

`output_bs.maude` is generated. Prefer changing `translator_bs.ml` and
regenerating rather than hand-editing the generated file.

## 3. Load The Maude Runtime Harness

```bash
maude wasm-exec-bs.maude
```

Expected load behavior:

```text
no Warning
no Advisory
no Error
```

Load chain:

```text
wasm-exec-bs.maude
  -> wasm-init-bs.maude
  -> builtins.maude
  -> output_bs.maude
```

## 4. Direct Maude Smokes

Run inside Maude after loading `wasm-exec-bs.maude`.

### Fibonacci steps

```maude
rew [1] in WASM-FIB-BS :
  steps(fib-config(i32v(5))) .
```

Expected final result:

```maude
result Config: (fib-store ; empty-frame) ; CTORCONSTA2(CTORI32A0, 5)
```

### Fibonacci invoke path

```maude
rew [10000] in WASM-FIB-BS :
  steps(fib-config-invoke(i32v(5))) .
```

Expected final value:

```maude
CTORCONSTA2(CTORI32A0, 5)
```

### Instantiate/init path

```maude
red in WASM-FIB-BS :
  $instantiate(empty-store, fib-module, eps) .

rew [1] in WASM-FIB-BS :
  steps(fib-init-config(i32v(5))) .
```

Expected final value:

```maude
CTORCONSTA2(CTORI32A0, 5)
```

### Search syntax note

Use explicit parentheses in search targets to avoid Maude parse ambiguity:

```maude
search [1] in WASM-FIB-BS :
  steps(fib-config(i32v(5)))
  =>* ((fib-store ; empty-frame) ; CTORCONSTA2(CTORI32A0, 5)) .
```

## 5. WAT/Wasm Frontend Smokes

Run Fibonacci from WAT:

```bash
dune exec ./wasm_to_maude.exe -- --result-only --checked-run --run 5 wat_examples/fib.wat
```

Expected:

```text
result: CTORCONSTA2(CTORI32A0, 5)
```

Run a `.wasm` input:

```bash
wat2wasm --enable-all wat_examples/fib.wat -o /tmp/fib.wasm
dune exec ./wasm_to_maude.exe -- --result-only --checked-run --run 5 /tmp/fib.wasm
```

Validation only:

```bash
dune exec ./wasm_to_maude.exe -- --validate-only --result-only wat_examples/fib.wat
```

Expected:

```text
result: valid
```

Generate a standalone Maude harness:

```bash
dune exec ./wasm_to_maude.exe -- wat_examples/fib.wat > /tmp/fib.generated.maude
maude /tmp/fib.generated.maude
```

## 6. Local WAT Runtime Examples

```bash
dune exec ./wasm_to_maude.exe -- --result-only --checked-run --run-main wat_examples/global-get.wat
dune exec ./wasm_to_maude.exe -- --result-only --checked-run --run-main wat_examples/memory-size.wat
dune exec ./wasm_to_maude.exe -- --result-only --checked-run --run-main wat_examples/table-size.wat
dune exec ./wasm_to_maude.exe -- --result-only --checked-run --run-main wat_examples/start-global.wat
dune exec ./wasm_to_maude.exe -- --result-only --checked-run --run-main wat_examples/data-load.wat
dune exec ./wasm_to_maude.exe -- --result-only --checked-run --run-main wat_examples/elem-call-ref.wat
```

Expected final values:

```text
global-get    => CTORCONSTA2(CTORI32A0, 42)
memory-size   => CTORCONSTA2(CTORI32A0, 0)
table-size    => CTORCONSTA2(CTORI32A0, 3)
start-global  => CTORCONSTA2(CTORI32A0, 7)
data-load     => CTORCONSTA2(CTORI32A0, 42)
elem-call-ref => CTORCONSTA2(CTORI32A0, 9)
```

## 7. Import Examples

Function import:

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

Global, memory, table imports:

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

Expected:

```text
import-global => CTORCONSTA2(CTORI32A0, 77)
import-memory => CTORCONSTA2(CTORI32A0, 1)
import-table  => CTORCONSTA2(CTORI32A0, 4)
```

## 8. Invalid Input Smoke

Normal frontend path should reject invalid WAT/Wasm before runtime:

```bash
dune exec ./wasm_to_maude.exe -- --checked-run --result-only --run-main \
  wat_examples/invalid-result-type.wat
```

This file declares an `i32` result but returns `i64.const 1`, so WABT should
reject it.

The benchmark runner also checks a Maude-internal path using `--no-canonicalize`:
the generated invalid module does not satisfy `Module-ok`, so checked-run stays
blocked instead of running `steps`.

## 9. Regression

Run the full current regression:

```bash
scripts/run_c1_regression.sh
```

The script writes an artifact directory:

```text
artifacts/c1-regression-YYYYMMDD_HHMMSS
```

It performs:

1. WABT tool check,
2. `dune build`,
3. `output_bs.maude` regeneration,
4. structural invariant checks,
5. WAT/Wasm benchmark probes,
6. direct local WAT smokes,
7. C1 probe matrix,
8. Maude load warning classification,
9. non-isomorphic helper inventory.

Latest checked summary:

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

## 10. Benchmark Classifier Only

Fetch external benchmarks when needed:

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

Main status buckets:

```text
PASS              expected result matches
STEPPED           execution ended, no expected result available
INVALID           invalid input rejected or Module-ok not valid
NO_ENTRY          no exported/main function to call
IMPORT_MISSING    host import not provided
UNSUPPORTED       syntax/instruction not supported yet
STUCK_VALIDATION  Module-ok validation stuck/timeout
STUCK_STEP        runtime steps stuck/timeout
WRONG_RESULT      execution ended with wrong value
WABT_FAIL         WABT cannot parse/validate the file
FAIL              uncategorized failure
```

## 11. Generated-Core Sanity Checks

No old pure-step bridge:

```bash
rg '^  (rl|crl) \\[step-from-step-pure' output_bs.maude
```

Expected: no matches.

No old value-sequence Boolean guard:

```bash
rg '\\$is-spectec-val-seq|\\$is-spectec-val' output_bs.maude
```

Expected: no matches.

Current source `val*` representation:

```bash
rg 'sort ValSeq|var .* : ValSeq|vars .* : ValSeq' output_bs.maude
```

Expected: matches.

No broad SpectecType-as-runtime-terminal relation:

```bash
rg 'subsort SpectecType < SpectecTerminal|subsort SpectecTypes < SpectecTerminals' output_bs.maude
```

Expected: no matches.

## 12. Model Checking

Model checking is not part of the current C1 acceptance target. Keep it
separate from translator/frontend/runtime cleanup unless explicitly resumed.
