# How To Test The Current C1 Baseline

Updated: 2026-05-26

This document contains the current manual smoke commands for the active C1 path:

```text
translator_bs.ml
output_bs.maude
builtins.maude
wasm-init-bs.maude
wasm-exec-bs.maude
```

## 1. Regenerate

```bash
dune build ./main_bs.exe
dune exec ./main_bs.exe -- wasm-3.0/*.spectec > output_bs.maude
```

## 2. Load

```bash
maude wasm-exec-bs.maude
```

Expected: no `Warning`, no `Advisory`, no `Error` while loading.

Load chain:

```text
wasm-exec-bs.maude -> wasm-init-bs.maude -> builtins.maude -> output_bs.maude
```

If your shell cannot find Maude, fix your local `PATH` first. The Codex shell in
some environments may not inherit the same `maude` command that an interactive
terminal has.

## 3. Basic Runtime Smokes

Run inside Maude after loading `wasm-exec-bs.maude`.

### 3.1 step-pure

```maude
rew [1] in WASM-FIB-BS : step-pure(CTORNOPA0) .
search [1] in WASM-FIB-BS : step-pure(CTORNOPA0) =>* eps .
```

### 3.2 step-read

Null `throw_ref` should trap:

```maude
rew [1] in WASM-FIB-BS :
  step-read((((fib-store ; empty-frame).State) ;
    CTORREFNULLA1(CTORFUNCA0) CTORTHROWREFA0)) .

search [1] in WASM-FIB-BS :
  step-read((((fib-store ; empty-frame).State) ;
    CTORREFNULLA1(CTORFUNCA0) CTORTHROWREFA0))
  =>* CTORTRAPA0 .
```

### 3.3 step / steps

```maude
rew [1] in WASM-FIB-BS :
  step(fib-config(i32v(5))) .

rew [1] in WASM-FIB-BS :
  steps(fib-config(i32v(5))) .
```

Expected final result:

```maude
result Config: (fib-store ; empty-frame) ; CTORCONSTA2(CTORI32A0, 5)
```

Use explicit parentheses in search targets to avoid Maude parse ambiguity:

```maude
search [1] in WASM-FIB-BS :
  steps(fib-config(i32v(5)))
  =>* ((fib-store ; empty-frame) ; CTORCONSTA2(CTORI32A0, 5)) .
```

## 4. Invoke Path Smoke

```maude
rew [10000] in WASM-FIB-BS :
  steps(fib-config-invoke(i32v(5))) .
```

Expected final result:

```maude
result Config: (fib-store ; $empty-frame) ; CTORCONSTA2(CTORI32A0, 5)
```

## 5. Instantiate / Init Config Smoke

This checks the source-shaped module initialization path:

```maude
red in WASM-FIB-BS :
  $instantiate(empty-store, fib-module, eps) .

rew [1] in WASM-FIB-BS :
  steps(fib-init-config(i32v(5))) .
```

Expected final result:

```maude
result Config: (... ; $empty-frame) ; CTORCONSTA2(CTORI32A0, 5)
```

The store is generated from `fib-module` through `$instantiate`, not from the
manual `fib-store` oracle.

## 6. Focused WAT Frontend Smokes

Generate a Maude harness from the focused function-module WAT subset:

```bash
dune exec ./wat_to_maude_fib.exe -- examples/fib.wat > /tmp/fib.generated.maude
maude /tmp/fib.generated.maude
```

Run inside Maude:

```maude
rew [1] in WASM-FIB-GENERATED-BS :
  steps(generated-fib-init-config(i32v(5))) .
```

Expected final result:

```maude
result Config: (... ; $empty-frame) ; CTORCONSTA2(CTORI32A0, 5)
```

The CLI can also generate and run in one step:

```bash
dune exec ./wat_to_maude_fib.exe -- --run 5 examples/fib.wat
```

The current frontend also supports multiple function types, imports as
source-shaped terms, globals, memories, tables, data segments, element segments,
start, multiple local functions, function exports, direct `call`, `call_ref`,
and flat or folded `block` / `loop` forms in the focused executable subset:

```bash
dune exec ./wat_to_maude_fib.exe -- --invoke-index 1 --run 5 examples/fib-wrapper.wat
```

Expected final result:

```maude
result Config: (... ; $empty-frame) ; CTORCONSTA2(CTORI32A0, 5)
```

Additional focused runtime examples:

```bash
dune exec ./wat_to_maude_fib.exe -- --run-main examples/global-get.wat
dune exec ./wat_to_maude_fib.exe -- --run-main examples/memory-size.wat
dune exec ./wat_to_maude_fib.exe -- --run-main examples/table-size.wat
dune exec ./wat_to_maude_fib.exe -- --run-main examples/start-global.wat
dune exec ./wat_to_maude_fib.exe -- --run-main examples/data-load.wat
dune exec ./wat_to_maude_fib.exe -- --run-main examples/elem-call-ref.wat
```

Expected final values:

```text
global-get  => CTORCONSTA2(CTORI32A0, 42)
memory-size => CTORCONSTA2(CTORI32A0, 0)
table-size  => CTORCONSTA2(CTORI32A0, 3)
start-global => CTORCONSTA2(CTORI32A0, 7)
data-load   => CTORCONSTA2(CTORI32A0, 42)
elem-call-ref => CTORCONSTA2(CTORI32A0, 9)
```

The frontend can parse function imports and emits source-shaped import/export
terms. The CLI can build the compatible base store and externaddr list for
function, global, memory, and table imports:

```bash
dune exec ./wat_to_maude_fib.exe -- --result-only --run-export main --arg-i32 41 \
  --import-func 'env.bump=local.get 0 i32.const 1 i32.add' \
  examples/import-func.wat
dune exec ./wat_to_maude_fib.exe -- --result-only --run-export main \
  --import-global 'env.g=i32.const 77' examples/import-global.wat
dune exec ./wat_to_maude_fib.exe -- --result-only --run-export main examples/import-memory.wat
dune exec ./wat_to_maude_fib.exe -- --result-only --run-export main examples/import-table.wat
```

Expected final value:

```maude
import-func   => CTORCONSTA2(CTORI32A0, 42)
import-global => CTORCONSTA2(CTORI32A0, 77)
import-memory => CTORCONSTA2(CTORI32A0, 1)
import-table  => CTORCONSTA2(CTORI32A0, 4)
```

`elem-call-ref.wat` uses an active element segment. The generated config calls
the source-translated `$instantiate`, which emits the element/table init work;
execution currently relies on the source-derived table/elem helper bridges in
`output_bs.maude`.

## 7. Focused Context Smokes

These check that the broad `SpectecTerminals` carrier still executes common
`val* instr* instr_1*` context shapes.

### 7.1 label/br + suffix

```maude
search [5] in WASM-FIB-BS :
  step((fib-store ;
    RECFrameA2(
      CTORCONSTA2(CTORI32A0, 0)
      CTORCONSTA2(CTORI32A0, 5)
      CTORCONSTA2(CTORI32A0, 8)
      CTORCONSTA2(CTORI32A0, 8),
      fib-moduleinst)) ;
    CTORLABELLBRACERBRACEA3(0, eps, CTORBRA1(0))
    CTORLOCALGETA1(1))
  =>* C:Config .
```

Expected: `Solution 1`, ending with the suffix instruction preserved:

```maude
CTORLOCALGETA1(1)
```

### 7.2 br_if + suffix

```maude
search [5] in WASM-FIB-BS :
  step(((fib-store ; empty-frame).State ;
    CTORCONSTA2(CTORI32A0, 1) CTORBRIFA1(0) CTORLOCALGETA1(1)))
  =>* C:Config .
```

Expected: `Solution 1`.

### 7.3 nop + suffix

```maude
search [5] in WASM-FIB-BS :
  step(((fib-store ; empty-frame).State ;
    CTORNOPA0 CTORLOCALGETA1(0)))
  =>* C:Config .
```

Expected: `Solution 1`.

## 8. Reference / Cast Smokes

The current focused evidence records these as passing in
`artifacts/wasmtype-cleanup-audit-20260525_054200/summary.md`:

```text
ref.test negative => CTORCONSTA2(CTORI32A0, 0)
ref.test positive => CTORCONSTA2(CTORI32A0, 1)
ref.cast negative => CTORTRAPA0
ref.cast positive => CTORREFI31NUMA1(7)
```

Use the concrete commands in the probe scripts/artifacts when re-running the
full focused matrix.

## 9. Typecheck / Category Cleanup Sanity Checks

These are shell checks against the generated output:

```bash
rg 'mod SPECTEC-CATEGORIES|hasType|WellTyped' output_bs.maude
rg '^  (mb|cmb) ' output_bs.maude
rg 'subsort SpectecType < SpectecTerminal|subsort SpectecTypes < SpectecTerminals' output_bs.maude
```

Expected: no matches.

The remaining source-derived sequence-shape predicates should be:

```bash
rg '\$is-spectec-' output_bs.maude
```

Expected: only `$is-spectec-val` and `$is-spectec-val-seq` definitions/usages.

The current generic step-pure context bridge should be the only
`step-from-step-pure` rule:

```bash
rg '^  (rl|crl) \[step-from-step-pure' output_bs.maude
```

Expected:

```text
crl [step-from-step-pure-ctxt-instrs] :
```

## 10. Model Checking

Model checking is not part of the current C1 acceptance target. Keep it separate
from C1 isomorphism and runtime cleanup unless the professor explicitly resumes
that thread.
