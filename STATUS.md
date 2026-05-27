# Spec2Maude C1 Status

Updated: 2026-05-27

This is the current handoff document for the active WebAssembly C1 baseline.
For commands, read `docs/HowToTest.md`. For limitations/discussion points, read
`docs/limitation.md`.

## One-Line State

Spec2Maude now has a warning-free C1 WebAssembly SpecTec-to-Maude core, an
OCaml `.wat` / `.wasm` frontend, checked execution through `Module-ok`, and a
benchmark runner that classifies failures by pipeline stage.  It is strong
enough for focused paper experiments, but not yet complete WebAssembly 3.0
coverage.

## Main Pipeline

```text
.wat / .wasm
  -> WABT canonicalization / validation
  -> wasm_to_maude.ml frontend
  -> generated Maude module term
  -> Module-ok validation
  -> $instantiate
  -> invoke / call_ref
  -> steps
  -> result comparison
```

Important separation:

- `output_bs.maude`: generated SpecTec-to-Maude core.
- `wasm-init-bs.maude`: init/config/runtime harness helpers.
- `builtins.maude`: backend/builtin Maude definitions.
- `wasm_to_maude.ml`: WAT/Wasm frontend.
- `scripts/run_wasm_benchmarks.py`: benchmark/spec-test classifier.

## Current C1 Criteria

1. Preserve SpecTec syntax / def / rule structure and intent.
2. SpecTec `def` lowers to Maude `eq/ceq`.
3. SpecTec `rule` lowers to Maude `rl/crl`.
4. Unconditional source rules should stay unconditional when possible.
5. Source-absent helpers should not remain in `output_bs.maude` unless they are
   unavoidable representation substrate, source-derived execution
   infrastructure, or explicitly accepted.

## Latest Regression Snapshot

Latest checked artifact:

```text
artifacts/c1-regression-20260527_133237
```

Summary:

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

Bucket meanings:

- `PASS`: validation, init, execution, and expected-result comparison succeeded.
- `STEPPED`: execution reached a final config, but no expected result was
  available.
- `INVALID`: invalid input was rejected, or `Module-ok` did not prove validity.
- `NO_ENTRY`: no callable export/main entry exists.
- `IMPORT_MISSING`: required host import is not linked.
- `UNSUPPORTED`: frontend or runner intentionally does not support the syntax
  yet.
- `STUCK_VALIDATION`: `Module-ok` / validation did not finish as `valid`.
- `STUCK_STEP`: runtime `steps` got stuck, timed out, or left an administrative
  term.
- `WRONG_RESULT`: execution ended but the observed result differs from the
  expected value.

## Structural Coverage

Current generated C1 core structurally covers the WebAssembly 3.0 SpecTec files
in this repository:

```text
source files:                       21 / 21
syntax declarations:                249 / 249
def declarations/equations:          1272 / 1272
relation declarations:               82 / 82
rule declarations:                   499 / 499
strict validation source-rule targets: 281 / 281 primary rl/crl
missing source constructs:           0 known
eq/ceq ... = valid:                  0
iter-empty / opt-empty labels:       0
```

## Current Isomorphism State

Resolved or improved:

- `step-from-step-pure-*` rules are no longer generated.
- `$is-spectec-val-seq` is no longer generated.
- Source `val*` is represented with a Maude `ValSeq` sort:

```maude
sort ValSeq .
subsort Val < ValSeq .
subsort ValSeq < SpectecTerminals .
op eps : -> ValSeq .
op _ _ : ValSeq ValSeq -> ValSeq [ctor assoc id: eps] .
```

Remaining discussion items:

1. `$infer-*` witness inference overlay.
2. Source-derived relation decision mirrors such as `$heaptype-sub?` /
   `$reftype-sub?`.
3. Continuation/result/map scaffolding for executable `def` equations:
   `$cont-*`, `$result-*`, `$valid-*`, `$map-*`.
4. Runtime/init harness helpers in `wasm-init-bs.maude`.
5. Any temporary bridge that remains in `output_bs.maude`, especially around
   execution paths that should ideally be handled by the literal generated
   source rule.

Key point for reporting:

```text
No benchmark-specific hardcoding was added to output_bs.maude.
The remaining non-source machinery should be explained as source-derived
execution infrastructure or moved out of the generated core.
```

## Typecheck / Validation State

Do not say "typecheck was removed" without qualification.

Current accurate statement:

```text
SpecTec validation relations remain:
Module-ok, Func-ok, Instr-ok, Instrs-ok, Reftype-sub, Heaptype-sub, ...

Duplicate runtime category guards were reduced/removed where possible:
hasType / WellTyped
general $is-spectec-* runtime predicates
old $is-spectec-val-seq predicate
```

Invalid input handling:

- Normal `.wat` / `.wasm` frontend path uses WABT validation before Maude
  runtime.
- Checked execution also requires
  `Module-ok(generated-fib-module, generated-module-type) => valid`.
- If `Module-ok` does not prove validity, checked-run does not enter
  `$instantiate` / `steps`.

For formal discussion, emphasize the Maude `Module-ok` gate. WABT is useful
engineering validation, not the formal semantics argument by itself.

## SpectecType Ground-Term Cleanup

Current generated prelude separates runtime terms from category/type labels:

```maude
sort SpectecTerminal .
sort SpectecType .
sort SpectecCategory .
subsort SpectecType < SpectecCategory .
```

Removed:

```maude
subsort SpectecType < SpectecTerminal .
subsort SpectecTypes < SpectecTerminals .
```

Generic category helpers now take category labels:

```maude
op $concat   : SpectecCategory SpectecTerminals -> SpectecTerminals .
op $disjoint : SpectecCategory SpectecTerminals -> Bool .
op $setminus : SpectecCategory SpectecTerminals SpectecTerminals -> SpectecTerminals .
```

Parametric type/category constructors now use narrower source-shaped parameter
sorts:

```maude
op iN    : N -> SpectecType .
op vec   : Vnn -> SpectecType .
op binop : Numtype -> SpectecType .
op list  : SpectecCategory -> SpectecType .
```

This fixed the translator bug where meaningless ground type terms such as
`iN(CTORNOPA0)` could be accepted.

## Frontend Coverage

The OCaml frontend currently supports the local smoke suite and a growing
official-spec subset:

```text
module/type/func/import/export
global/memory/table/data/elem/start
direct call/call_ref/call_indirect
block/loop/if/br/br_if/br_table
local/global get/set/tee
memory load/store/init/copy/fill/size/grow
table get/set/size/grow/fill/init/copy/elem.drop
i32/i64/f32/f64 constants, numeric ops, relops, conversions
selected v128/SIMD/relaxed-SIMD term generation
selected ref types and ref instructions
```

It is not yet a full WAT parser or a complete WebAssembly 3.0 implementation.

## What To Work On Next

Priority order:

1. Reduce `STUCK_VALIDATION`.
   - Focus: `Module-ok`, `Instrs-ok`, unreachable/polymorphic validation,
     table64/memory64 validation, local initialization.
2. Reduce `STUCK_STEP`.
   - Focus: memory.fill/copy/grow, ref/null paths, SIMD/relaxed-SIMD admin
     contexts.
3. Reduce `WRONG_RESULT`.
   - Focus: memory byte builtins, data.drop, linking/import state, ref.is_null,
     float load/store.
4. Expand unsupported frontend syntax.
   - Focus: exception/tag forms, proposal syntax, WABT/wasm-tools fallback.
5. Keep auditing helper boundaries.
   - Keep `output_bs.maude` as source-derived as possible.
   - Put frontend/init harness code in `wasm-init-bs.maude`.

## Professor-Discussion Notes

Recommended framing:

1. `val*` is now represented with `ValSeq`; the old Boolean guard and
   pure-step bridge are gone.
2. Typecheck was not blindly removed. SpecTec validation remains, and checked
   run is gated by `Module-ok`.
3. `iN(NOP)` was a translator bug caused by an overly broad `SpectecType`
   signature; it has been fixed by separating `SpectecCategory`.
4. The main remaining strict non-isomorphism topic is `$infer-*` witness
   inference and related source-derived execution infrastructure.

## Fresh Chat Prompt

```text
You are working on my Spec2Maude C1 baseline.

Read these first:
- STATUS.md
- docs/limitation.md
- docs/HowToTest.md

Current state:
- output_bs.maude is the generated WebAssembly SpecTec-to-Maude core.
- wasm_to_maude.ml is the WAT/Wasm frontend.
- wasm-init-bs.maude is the init/runtime harness.
- step-from-step-pure count is 0.
- $is-spectec-val-seq is gone; source val* uses ValSeq.
- Checked execution is gated by Module-ok.

Do not assume old docs under docs/archive are current.
Do not hand-edit output_bs.maude unless explicitly asked.
```
