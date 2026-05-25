# Spec2Maude C1 Status

Updated: 2026-05-26

This is the current handoff document for the WebAssembly C1 baseline. Read it
with `docs/limitation.md` before changing `translator_bs.ml`.

## One-Line State

C1 structurally covers the WebAssembly 3.0 SpecTec input and has a warning-free
minimal runtime/typecheck cleanup in the generated output. The remaining C1
decisions are about whether a small number of source-derived execution helpers
belong in C1 or should be pushed to a later C2 execution layer.

## Current C1 Criteria

1. Preserve SpecTec source syntax / def / rule structure and intent.
2. Variable names and Maude internal names may differ.
3. Source-absent helpers should not remain in C1 unless they are unavoidable
   representation substrate, source-derived execution infrastructure, or
   explicitly accepted.
4. SpecTec unconditional rules should lower to Maude unconditional rules;
   conditional rules should lower to conditional rules.
5. SpecTec `def` should lower to Maude `eq/ceq`; SpecTec `rule` should lower
   to Maude `rl/crl`.

## Read First

Use this order in a fresh Codex chat:

1. `STATUS.md`
2. `docs/limitation.md`
3. `docs/HowToTest.md`
4. `artifacts/rule-concrete-audit-20260525_004500/summary.md`
5. `artifacts/wasmtype-cleanup-audit-20260525_054200/summary.md`
6. `artifacts/c1-probe-matrix-20260525_004421/probe_summary.md`

Archive docs under `docs/archive/` are evidence/history, not current state.

## Build And Regenerate

```bash
dune build ./main_bs.exe
dune exec ./main_bs.exe -- wasm-3.0/*.spectec > output_bs.maude
```

Load execution:

```bash
maude wasm-exec-bs.maude
```

`wasm-exec-bs.maude` loads `builtins.maude`, which loads `output_bs.maude`.

## Structural Facts

```text
source files:                      21 / 21
syntax declarations:               249 / 249
def declarations/equations:         1272 / 1272
relation declarations:              82 / 82
rule declarations:                  499 / 499
strict validation source-rule targets: 281 / 281 primary rl/crl
missing source constructs:          0 known
eq/ceq ... = valid:                 0
iter-empty / opt-empty labels:      0
```

Source `def` clauses that previously emitted as `rl/crl`
(`evalexprs-r1`, `evalexprss-r1`, `evalglobals-r1`, `instantiate-r0`) are now
back in `eq/ceq` shape using source-derived result / continuation mirrors.

## Current Non-Isomorphic / Professor-Discussion Items

### 1. Category / Sequence Gap + Generic Step-Pure Context Bridge

Current broad sequence carrier:

```maude
SpectecTerminals
op __ : SpectecTerminals SpectecTerminals -> SpectecTerminals [assoc id: eps] .
```

Because `val*`, `instr*`, and `instr_1*` are not separate sequence sorts, the
generated `Step/ctxt-instrs` rule keeps a minimal value-prefix guard:

```maude
crl [step-ctxt-instrs] :
  step((Z ; VALS INSTRS INSTRS1))
  =>
  (ZQ ; VALS INSTRSQ INSTRS1)
  if $is-spectec-val-seq(VALS)
  /\ (VALS =/= eps \/ INSTRS1 =/= eps)
  /\ step((Z ; INSTRS)) => (ZQ ; INSTRSQ) .
```

The current output also contains one generic bridge for pure steps under the
same context shape:

```maude
crl [step-from-step-pure-ctxt-instrs] :
  step((Z ; VALS INSTRS INSTRS1))
  =>
  (Z ; VALS INSTRSQ INSTRS1)
  if $is-spectec-val-seq(VALS)
  /\ (VALS =/= eps \/ INSTRS1 =/= eps)
  /\ step-pure(INSTRS) => INSTRSQ .
```

Discussion question: can this source-derived sequence-shape guard and generic
bridge remain in C1?

### 2. `$infer-*` Witness Inference Overlay

Source relation premises can expose intermediate witnesses such as `TS2`.
The current `Judgement => valid` encoding proves validity but does not return
those witnesses directly. `$infer-*` helpers are generated from source premise
structure, but they are still source-absent execution overlay.

Discussion question: can this remain in C1, or is witness synthesis a C2 solver
feature?

## Typecheck Cleanup State

Under the well-typed-input assumption, current generated runtime output removes
the broad category/typecheck layer from execution:

```text
SPECTEC-CATEGORIES: absent
mb / cmb category axioms: absent
hasType / WellTyped: absent
general $is-spectec-* category predicates: absent
```

Only these sequence-shape predicates remain:

```maude
$is-spectec-val
$is-spectec-val-seq
```

They are used to keep `val*` prefixes from matching arbitrary instruction/type
sequences in the broad `SpectecTerminals` carrier. They should be presented as
runtime sequence-shape infrastructure, not full validation/typechecking.

This cleanup does not remove:

- Wasm type syntax such as `i32`, `functype`, `reftype`, `heaptype`;
- SpecTec validation relations such as `Instr-ok`, `Instrs-ok`, `Module-ok`,
  `Func-ok`, `Reftype-sub`, `Heaptype-sub`.

## SpectecType Ground-Term Cleanup State

Current generated prelude separates runtime terminals from category/type labels:

```maude
sort SpectecTerminal .
sort SpectecType .
sort SpectecCategory .
subsort SpectecType < SpectecCategory .
```

Current output has no:

```maude
subsort SpectecType < SpectecTerminal .
subsort SpectecTypes < SpectecTerminals .
```

Generic source helpers use category labels:

```maude
op $concat  : SpectecCategory SpectecTerminals -> SpectecTerminals .
op $disjoint : SpectecCategory SpectecTerminals -> Bool .
op $setminus : SpectecCategory SpectecTerminals SpectecTerminals -> SpectecTerminals .
```

Parametric type constructors use source-shaped parameter sorts, not broad
`SpectecTerminal`:

```maude
op iN    : N -> SpectecType .
op vec   : Vnn -> SpectecType .
op binop : Numtype -> SpectecType .
op list  : SpectecCategory -> SpectecType .
```

This directly addresses the meaningless ground-type-term issue such as
`iN(CTORNOPA0)`.

## Execution Evidence

Broad concrete audit:

```text
artifacts/rule-concrete-audit-20260525_004500/summary.md
total rl/crl: 830
REDUCED: 559
STUCK: 271
STACK_OVERFLOW: 0
MAUDE_EXIT: 0
TIMEOUT: 0
```

The `271 STUCK` samples are generated concrete samples, not proof that each
source rule is wrong. Many lack a source-valid context/store/module/type
witness.

Focused evidence:

- `artifacts/c1-probe-matrix-20260525_004421/probe_summary.md`: last all-pass
  matrix before type-signature expectation drift, `43 PASS`.
- `artifacts/wasmtype-cleanup-audit-20260525_054200/summary.md`: records direct
  focused runtime success after typecheck / SpectecType cleanup.
- `artifacts/c1-probe-matrix-20260525_054128/probe_summary.md`: newest matrix,
  but many rows fail because expected result sort strings became stale after
  the type cleanup.

Representative direct focused paths currently considered passing:

- `steps(fib-config(i32v(5)))`;
- `steps(fib-config-invoke(i32v(5)))`;
- reference/cast `ref.test` positive and negative;
- reference/cast `ref.cast` positive and negative;
- label/br suffix search;
- br_if suffix search;
- nop suffix search.

## Known Limitations

1. The broad audit still has `271 STUCK` generated samples.
2. True nested sequence representation such as explicit `expr**` inner grouping
   is still a representation issue, although focused flat `$evalexprss` paths
   execute.
3. Builtin backend coverage is partial. `builtins.maude` currently implements
   only the concrete backend paths needed by current focused tests.
4. `$infer-*`, `$heaptype-sub?` / `$reftype-sub?`, `$cont-*`, `$valid-*`,
   `$result-*`, and `$map-*` remain source-derived execution views rather than
   literal source names.

## What To Ask Professor

1. Should C1 be a structural/isomorphic baseline with representative execution
   smokes, or must every generated rule have a source-valid concrete execution
   sample?
2. Are `$is-spectec-val-seq` and `step-from-step-pure-ctxt-instrs` acceptable
   C1 infrastructure?
3. Are `$infer-*` witness helpers acceptable in C1?
4. Is the current runtime typecheck cleanup enough, with only minimal
   sequence-shape guards left?
5. Should typed/mixed/nested sequence sorts be designed now or postponed?
6. Can source-derived `otherwise` decision mirrors for reference/cast paths
   remain in C1?

## Fresh Chat Prompt

```text
You are working on my Spec2Maude C1 baseline.

Please first read:
- STATUS.md
- docs/limitation.md
- docs/HowToTest.md
- artifacts/rule-concrete-audit-20260525_004500/summary.md
- artifacts/wasmtype-cleanup-audit-20260525_054200/summary.md
- artifacts/c1-probe-matrix-20260525_004421/probe_summary.md

Current goal:
C1 is a faithful WebAssembly SpecTec-to-Maude baseline. Do not assume old
archive docs are current. Do not blindly edit translator_bs.ml.

Current professor-discussion items:
1. Category / sequence representation gap plus generic step-pure context bridge.
2. $infer-* witness inference overlay.
3. Runtime typecheck cleanup leaves only minimal val* sequence-shape guards.
4. SpectecType ground-term universe has been narrowed with SpectecCategory.

Before changing code, inspect current output_bs.maude, translator_bs.ml,
docs/limitation.md, and the current artifacts listed above.
```
