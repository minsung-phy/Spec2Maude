# How To Test Spec2Maude

Updated: 2026-05-29

Use this document for reproducible local checks.

## 1. Tool Check

```bash
eval "$(opam env)"
command -v dune
command -v maude || echo "set MAUDE_BIN=/path/to/maude"
command -v wast2json || echo "needed only for official .wast test slices"
```

If Maude is not on `PATH`:

```bash
export MAUDE_BIN=/path/to/maude
```

## 2. Build

```bash
make build
```

This creates:

```text
./spec2maude
```

## 3. Recommended CLI Checks

```bash
./spec2maude --help
./spec2maude validate wat_examples/fib.wat
./spec2maude run wat_examples/fib.wat --fib 5
./spec2maude run wat_examples/global-get.wat --main
make validate-invalid
```

Expected Fibonacci result:

```text
result: CTORCONSTA2(CTORI32A0, 5)
```

`validate` checks the official SpecTec/WebAssembly parser-validator path.  It
is intentionally not the Maude `Module-ok` path.

## 4. Regenerate The Maude Core

```bash
./spec2maude translate
```

Equivalent low-level command:

```bash
dune exec ./main_bs.exe -- wasm-3.0/*.spectec > output_bs.maude
```

`output_bs.maude` is generated.  Prefer changing `translator_bs.ml` and
regenerating instead of hand-editing it.

## 5. Load Maude Harness

```bash
maude wasm-exec-bs.maude
```

Expected:

```text
no Warning
no Error
```

Load chain:

```text
wasm-exec-bs.maude
  -> wasm-init-bs.maude
  -> builtins.maude
  -> output_bs.maude
```

## 6. Direct Maude Smoke

Inside Maude:

```maude
rew [1] in WASM-FIB-BS :
  steps(fib-config(i32v(5))) .
```

Expected final value:

```maude
CTORCONSTA2(CTORI32A0, 5)
```

## 7. WAT/Wasm Frontend Smokes

Low-level Fibonacci:

```bash
dune exec ./wasm_to_maude.exe -- --result-only --run 5 wat_examples/fib.wat
```

Generated harness should not include the experimental `Module-ok` block by
default:

```bash
dune exec ./wasm_to_maude.exe -- --output /tmp/fib.generated.maude wat_examples/fib.wat
rg 'Module-ok|generated-checked|generated-validation' /tmp/fib.generated.maude
```

Expected: no matches.

If you explicitly want the experimental Maude validation/debug block:

```bash
dune exec ./wasm_to_maude.exe -- --output /tmp/fib.checked.maude --checked-run wat_examples/fib.wat
rg 'Module-ok|generated-checked|generated-validation' /tmp/fib.checked.maude
```

Expected: matches.

## 8. Local Example Suite

```bash
./spec2maude run wat_examples/global-get.wat --main
./spec2maude run wat_examples/memory-size.wat --main
./spec2maude run wat_examples/table-size.wat --main
./spec2maude run wat_examples/start-global.wat --main
./spec2maude run wat_examples/data-load.wat --main
./spec2maude run wat_examples/elem-call-ref.wat --main
```

Expected values:

```text
global-get    => CTORCONSTA2(CTORI32A0, 42)
memory-size   => CTORCONSTA2(CTORI32A0, 0)
table-size    => CTORCONSTA2(CTORI32A0, 3)
start-global  => CTORCONSTA2(CTORI32A0, 7)
data-load     => CTORCONSTA2(CTORI32A0, 42)
elem-call-ref => CTORCONSTA2(CTORI32A0, 9)
```

## 9. Import Examples

Function import:

```bash
./spec2maude run wat_examples/import-func.wat \
  --export main \
  --arg-i32 41 \
  --import-func 'env.bump=local.get 0 i32.const 1 i32.add'
```

Expected:

```text
result: CTORCONSTA2(CTORI32A0, 42)
```

Other imports:

```bash
./spec2maude run wat_examples/import-global.wat \
  --export main \
  --import-global 'env.g=i32.const 77'

./spec2maude run wat_examples/import-memory.wat --export main
./spec2maude run wat_examples/import-table.wat --export main
```

## 10. Invalid Input

```bash
make validate-invalid
```

The example declares an `i32` result but returns `i64.const 1`; it should be
rejected by the frontend validation path before Maude runtime.

## 11. Regression

```bash
./spec2maude test smoke
./spec2maude test official --limit 20 --timeout 10
./spec2maude regression
```

The full regression writes artifacts under:

```text
artifacts/
```

## 12. Status Buckets

```text
PASS              expected result matched
STEPPED           execution terminated, no expected result available
INVALID           frontend validation rejected the input
NO_ENTRY          no exported/main function to call
IMPORT_MISSING    required host import was not supplied
UNSUPPORTED       syntax/instruction not supported yet
STUCK_VALIDATION  experimental Maude validation path stuck/timeout
STUCK_STEP        runtime steps stuck/timeout
WRONG_RESULT      execution terminated with wrong value
WABT_FAIL         wast2json/WABT could not expand an official .wast file
```

## 13. Generated-Core Sanity Checks

No old pure-step bridge:

```bash
rg '^  (rl|crl) \[step-from-step-pure' output_bs.maude
```

No old value-sequence Boolean guard:

```bash
rg '\$is-spectec-val-seq|\$is-spectec-val' output_bs.maude
```

No runtime-terminal subtype for `SpectecType`:

```bash
rg 'subsort SpectecType < SpectecTerminal|subsort SpectecTypes < SpectecTerminals' output_bs.maude
```

Expected for all three: no matches.
