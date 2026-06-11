# Translator Cleanup Plan

Updated: 2026-06-11

This file is the cleanup map for `translator.ml`.  The purpose is to make the
translator explainable and artifact-ready without changing the source-driven
translation discipline.

## Cleanup Rules

```text
1. Do not hand-edit output.maude.
2. Change translator.ml, regenerate output.maude, then test.
3. Do not add Wasm-specific constructor-name branches.
4. Preserve source intent:
   TypD -> SpectecType/typecheck/mb-cmb syntax layer
   DecD -> eq/ceq
   RelD -> rl/crl
5. Do not delete helper families until their source role is known.
6. Every cleanup slice must pass the artifact sanity checks.
```

## Current Translator Map

```text
1-2000       common utilities, identifiers, source constructor registry
2000-4200    source type environment and numeric/literal metadata
4200-4750    declaration state and helper registration
4750-7200    translate_exp: source expression -> Maude term text
7200-10500   translate_typd: syntax/typecheck/membership layer
10500-14900  binder, premise, and scheduling logic
14900-15400  translate_decd: source defs -> eq/ceq
15400-16850  translate_reld: source relations -> rl/crl
16850-19800  top-level translate, prelude, helper blocks, post-processing
```

## Current Sanity Checks

```bash
make build
./spec2maude translate -o output.maude
python3 scripts/audit_syntax_translation.py --strict-translator output.maude \
  --translator translator.ml --source-dir wasm-3.0
python3 scripts/audit_translator_cleanup.py
maude -no-banner wasm-exec.maude
./spec2maude run wat_examples/fib.wat --fib 5
./spec2maude test smoke --timeout 10
```

Expected shape:

```text
syntax audit              PASS
cleanup audit             PASS
Maude load                PASS, warning count currently 2
used-before-bound warning 0
fib                       result: const(i32, 5)
smoke                     PASS: 13
```

## Completed Cleanup

```text
old internal carrier nickname removed from translator implementation names
old baseline wording removed from generated comments
typed-index dead path removed from translator.ml
artifact warning count updated from 6 to 2
cleanup audit added
major translator entry points documented with contracts
```

## Remaining Helper Families

These names still appear in generated output and must be treated as design work,
not simple cleanup:

```text
$raw-lit/$wrap-lit     numeric representation boundary
$unmap-mapexpr-*       source pair-sequence inversion for vector defs
$map-* / $zipmap-*     source iterator/map lowering
$free-*                binder/free-variable support
$expanddt              source Expand premise computation
```

The translator also still contains relation-premise witness support for future
source profiles:

```text
$valid-* mirror support
$infer-* witness support
$result-* witness support
```

The current WebAssembly runtime artifact does not emit those helper names in
`output.maude`, but the code should be removed only after proving that no
supported source profile needs relation-premise witness synthesis.

## Next Cleanup Slices

```text
1. Decide whether relation-premise witness support belongs in runtime profile,
   full profile, or a separate module.
2. Document $raw-lit/$wrap-lit with source numeric examples.
3. Replace hash-like $unmap-mapexpr-* names with source-readable generated names.
4. Consider mechanical file split only after audits are stable.
```

