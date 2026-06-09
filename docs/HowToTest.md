# How To Test Spec2Maude

Updated: 2026-06-09

Use this document for reproducible local checks after restoring the
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
make build
./spec2maude translate -o output.maude
```

`output.maude` is generated.  Do not hand-edit it; change
`translator.ml` and regenerate.

For artifact review, start from a clean checkout and keep the generated
`output.maude` under version control only as a reproducible snapshot.  If it
differs after regeneration, inspect the translator diff rather than editing
the generated file.

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

The generated syntax layer should contain the restored carrier, category
checks, and constructor membership axioms:

```bash
rg 'sort SpectecType|op typecheck|mb |cmb ' output.maude
rg 'op syn-(instr|func|i32) : -> SpectecType' output.maude
rg 'op (func-externidx|func-externtype|func-func|sub-binop|sub-subtype)' output.maude
```

Expected: matches.

Source category/type witnesses are generated as `syn-* : SpectecType`; concrete
syntax constructors are generated as source-readable lowercase
`SpectecTerminal` terms such as `const(i32, 5)`.  The generated syntax layer
should not explode source categories into Maude sorts or emit old category
encodings:

```bash
rg '^[[:space:]]+(sort|subsort).*\b(Instr|Valtype|U32|Typeuse)\b' output.maude
rg 'SpectecCategory|WasmType|hasType|WellTyped|_hasType_|SortCTOR' output.maude
rg 'subsort Nat < U32|subsort Int < IN|subsort Nat < Byte' output.maude
rg --pcre2 '^[[:space:]]*op (?!syn-)[A-Za-z][A-Za-z0-9-]*.*-> SpectecType' output.maude
```

Expected: no matches.

Current load expectation: Maude should load with no errors, bad tokens, or
no-parse diagnostics.  Some parser-ambiguity warnings may remain because the
generated syntax intentionally keeps source-readable constructors and sequence
operators.

Current 2026-06-09 warning baseline:

```text
maude -no-banner output.maude      warnings: 6, fatal diagnostics: 0
maude -no-banner wasm-exec.maude   warnings: 6, fatal diagnostics: 0
```

Fatal diagnostics means any `Error:`, `no parse`, `bad token`,
`used before bound`, or `unpatchable` diagnostic.

Current warning breakdown:

```text
4 typed-index / source-sequence parser ambiguities
2 norm/subnorm float syntax ambiguities
```

Numeric `uN`/`sN` range equations are rendered in a source-readable form,
for example `I < 2 ^ N` and `N + - 1`, instead of Maude internal prefix
notation such as `_<=_(0, I)`.

## 3.1 Syntax Audit

Run the generated syntax/typecheck/membership audit:

```bash
python3 scripts/audit_syntax_translation.py output.maude --source-dir wasm-3.0
```

Expected:

```text
Syntax audit: output.maude
PASS: no required syntax/typecheck/membership failures found
```

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
result: const(i32, 5)
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
const(i32, 5)
```

`steps` is the source-shaped reflexive-transitive closure generated from the
SpecTec `Steps` relation.  Numeric payloads are raw Maude numerals; source
numeric categories are checked by generated `typecheck` equations.

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

Generated harness terms should use the current source-readable prefix surface,
not the old compact constructor surface:

```bash
rg 'const\(i32|func-func|local-get|binop|relop' /tmp/fib.generated.maude
rg 'CONST__|FUNC___|CALL_|WRESULT_|REFNULL_|VCONST__' /tmp/fib.generated.maude
```

Expected: the first command matches; the second command has no matches.

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
global-get    => const(i32, 42)
memory-size   => const(i32, 0)
table-size    => const(i32, 3)
start-global  => const(i32, 7)
data-load     => const(i32, 42)
elem-call-ref => const(i32, 9)
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
result: const(i32, 42)
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
import-global => const(i32, 77)
import-memory => const(i32, 1)
import-table  => const(i32, 4)
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

The benchmark runner compares expected results against the same source-readable
prefix terms emitted by the frontend, for example `const(i32, 5)`,
`ref-null(func-absheaptype)`, and `vconst(v128, ...)`.  It should not classify
results by searching for the old compact `CONST__`/`REFNULL_`/`VCONST__`
spelling.

Current local smoke expectation:

```text
Benchmark summary:
  PASS: 13
```

Current small official-slice reference, using the artifact command below:

```bash
./spec2maude test official --limit 30 --timeout 5
```

Expected 2026-06-09 bucket shape:

```text
Benchmark summary:
  INVALID: 10
  MODULE_STAGE: 40
  PASS: 43
  STUCK_INIT: 16
  STUCK_STEP: 69
  WRONG_RESULT: 3
```

This official-slice command is a progress probe, not a pass/fail artifact
claim.  The local smoke suite is the current required pass set.

## 11. Status Buckets

```text
PASS              expected result matched
STEPPED           execution terminated, no expected result available
MODULE_STAGE      official .wast command was module/link/setup only
INVALID           frontend validation rejected the input
NO_ENTRY          no exported/main function to call
IMPORT_MISSING    required host import was not supplied
UNSUPPORTED       syntax/instruction not supported yet
STUCK_INIT        initialization, instantiation, or harness setup stuck/timeout
STUCK_VALIDATION  experimental Maude validation path stuck/timeout
STUCK_STEP        runtime steps stuck/timeout
WRONG_RESULT      execution terminated with wrong value
WABT_FAIL         wast2json/WABT could not expand an official .wast file
```
