# How To Test Spec2Maude

Updated: 2026-06-03

Use this document for reproducible local checks after restoring the JHS-style
syntax/typecheck carrier and adding constructor membership axioms.

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

## 2. Build And Regenerate

```bash
dune build ./main.exe ./wasm_to_maude.exe ./spec2maude.exe
_build/default/spec2maude.exe translate -o output.maude
```

`output.maude` is generated.  Do not hand-edit it; change
`translator.ml` and regenerate.

## 3. Load Checks

```bash
maude -no-banner output.maude
maude -no-banner wasm-exec.maude
```

Load chain:

```text
wasm-exec.maude
  -> wasm-init.maude
  -> builtins.maude
  -> output.maude
```

The generated syntax layer should contain the restored JHS carrier, category
checks, and constructor membership axioms:

```bash
rg 'sort SpectecType|op typecheck|mb |cmb ' output.maude
```

Expected: matches.

The generated syntax layer should not explode source categories into Maude
sorts:

```bash
rg '^[[:space:]]+(sort|subsort).*\b(Instr|Valtype|U32|Typeuse)\b' output.maude
rg 'SpectecCategory|WasmType|hasType|WellTyped|_hasType_|SortCTOR' output.maude
rg 'subsort Nat < U32|subsort Int < IN|subsort Nat < Byte' output.maude
```

Expected: no matches.

## 4. Recommended CLI Checks

```bash
./spec2maude --help
./spec2maude validate wat_examples/fib.wat
./spec2maude run wat_examples/fib.wat --fib 5
./spec2maude test smoke --timeout 10
make validate-invalid
```

Expected Fibonacci result:

```text
result: CTORCONSTA2(CTORI32A0, litU32(5))
```

`validate` checks the official SpecTec/WebAssembly parser-validator path.  It
is intentionally not the Maude `Module-ok` path.

## 5. Direct Maude Smoke

Inside Maude:

```maude
rew [1] in WASM-FIB :
  steps(fib-config(i32v(5))) .
```

Expected final value:

```maude
CTORCONSTA2(CTORI32A0, litU32(5))
```

`steps` is the source-shaped reflexive-transitive closure generated from the
SpecTec `Steps` relation.  The numeric payload is wrapped because object-level
SpecTec/Wasm numeric literals are represented with explicit literal
constructors such as `litU32`.

## 6. WAT/Wasm Frontend Smokes

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

## 7. Local Example Suite

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
global-get    => CTORCONSTA2(CTORI32A0, litU32(42))
memory-size   => CTORCONSTA2(CTORI32A0, litU32(0))
table-size    => CTORCONSTA2(CTORI32A0, litU32(3))
start-global  => CTORCONSTA2(CTORI32A0, litU32(7))
data-load     => CTORCONSTA2(CTORI32A0, litU32(42))
elem-call-ref => CTORCONSTA2(CTORI32A0, litU32(9))
```

## 8. Import Examples

Function import:

```bash
./spec2maude run wat_examples/import-func.wat \
  --export main \
  --arg-i32 41 \
  --import-func 'env.bump=local.get 0 i32.const 1 i32.add'
```

Expected:

```text
result: CTORCONSTA2(CTORI32A0, litU32(42))
```

Other imports:

```bash
./spec2maude run wat_examples/import-global.wat \
  --export main \
  --import-global 'env.g=i32.const 77'

./spec2maude run wat_examples/import-memory.wat --export main
./spec2maude run wat_examples/import-table.wat --export main
```

Expected:

```text
import-global => CTORCONSTA2(CTORI32A0, litU32(77))
import-memory => CTORCONSTA2(CTORI32A0, litU32(1))
import-table  => CTORCONSTA2(CTORI32A0, litU32(4))
```

## 9. Invalid Input

```bash
make validate-invalid
```

The example declares an `i32` result but returns `i64.const 1`; it should be
rejected by the frontend validation path before Maude runtime.

## 10. Regression

```bash
./spec2maude test smoke --timeout 10
./spec2maude test official --limit 20 --timeout 10
```

Test runs write artifacts under `artifacts/`.  Regenerate the expected bucket
counts after syntax-carrier changes; parse/load regressions should be chased
before runtime-result regressions.

## 11. Status Buckets

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
