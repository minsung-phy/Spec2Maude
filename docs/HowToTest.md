# How To Test The Current C1 Baseline

Updated: 2026-05-26

This document contains the current manual smoke commands for the active C1 path:

```text
translator_bs.ml
output_bs.maude
builtins.maude
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

## 5. Focused Context Smokes

These check that the broad `SpectecTerminals` carrier still executes common
`val* instr* instr_1*` context shapes.

### 5.1 label/br + suffix

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

### 5.2 br_if + suffix

```maude
search [5] in WASM-FIB-BS :
  step(((fib-store ; empty-frame).State ;
    CTORCONSTA2(CTORI32A0, 1) CTORBRIFA1(0) CTORLOCALGETA1(1)))
  =>* C:Config .
```

Expected: `Solution 1`.

### 5.3 nop + suffix

```maude
search [5] in WASM-FIB-BS :
  step(((fib-store ; empty-frame).State ;
    CTORNOPA0 CTORLOCALGETA1(0)))
  =>* C:Config .
```

Expected: `Solution 1`.

## 6. Reference / Cast Smokes

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

## 7. Typecheck / Category Cleanup Sanity Checks

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

## 8. Model Checking

Model checking is not part of the current C1 acceptance target. Keep it separate
from C1 isomorphism and runtime cleanup unless the professor explicitly resumes
that thread.
