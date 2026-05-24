# Spec2Maude C1 Status

Updated: 2026-05-24

This is the current handoff document for the C1 baseline. Read this together
with `docs/limitation.md` before changing `translator_bs.ml`.

## One-Line State

The C1 WebAssembly SpecTec-to-Maude baseline is structurally covered and mostly
cleaned, but it is not yet a fully executable semantics for every generated
rule. The remaining decisions are about C1/C2 boundaries, not missing source
coverage.

## Current C1 Target

C1 means a faithful, relation-preserving baseline:

1. SpecTec syntax / def / rule structure and intent should be preserved.
2. Variable names and Maude internal names may differ.
3. Source-absent helpers, rules, conditions, or functions should not remain in
   the C1 core unless they are unavoidable representation substrate or
   explicitly accepted.
4. SpecTec unconditional rule should lower to Maude unconditional rule;
   conditional rule should lower to Maude conditional rule.
5. SpecTec `def` should lower to Maude `eq/ceq`; SpecTec `rule` should lower
   to Maude `rl/crl`.

## What To Read First

Use this order in a fresh Codex chat:

1. `STATUS.md`
2. `docs/limitation.md`
3. `docs/HowToTest.md`
4. `artifacts/rule-concrete-audit-20260525_004500/summary.md`
5. `artifacts/c1-probe-matrix-20260525_004421/probe_summary.md`

Archive docs under `docs/archive/` are evidence/history. Do not treat them as
the current state unless a current document explicitly points there.

## Build And Regenerate

```bash
dune build ./main_bs.exe
dune exec ./main_bs.exe -- wasm-3.0/*.spectec > output_bs.maude
```

`wasm-exec-bs.maude` loads `builtins.maude`, which then loads the generated
core. Do not forget `builtins.maude` when moving machines or committing.

## Current Structural Facts

- WebAssembly SpecTec source files audited: 21 / 21.
- Syntax declarations covered: 249 / 249.
- Def declarations/equations covered: 1272 / 1272.
- Relation declarations covered: 82 / 82.
- Rule declarations covered: 499 / 499.
- Missing source constructs currently known: 0.
- Strict validation source-rule targets: 281 / 281 primary `rl/crl`.
- No `eq/ceq ... = valid` remains in `output_bs.maude`.
- No `iter-empty` / `opt-empty` derived validation labels remain.
- Source `def` clauses that previously emitted as `rl/crl`
  (`evalexprs-r1`, `evalexprss-r1`, `evalglobals-r1`, `instantiate-r0`)
  have been moved back to `eq/ceq` shape using source-derived result /
  continuation mirrors.

## Current Non-Isomorphic / Professor-Discussion Items

The main C1 isomorphism discussion items are:

1. **20 label-related `step-from-step-pure-*` shortcuts**
   - Source has `Step_pure`, `Step/pure`, and `Step/ctxt-instrs`.
   - Output also contains 20 derived label-specific executable shortcuts.
   - They are needed for current label/br suffix execution, but they are not
     direct source rules.

2. **`$infer-*` witness inference overlay**
   - Source relation premises can expose intermediate witnesses such as `TS2`.
   - The current `Judgement => valid` encoding does not return those witnesses.
   - `$infer-*` helpers are generated from source premise structure, but they
     are still source-absent execution overlay.

3. **Category / sequence sort representation gap**
   - Some source category constraints remain as `$is-spectec-*`,
     `_hasType_`, and `WellTyped`.
   - Many record/simple category guards were removed, but full typed/mixed
     sequence sorts are not yet implemented.
   - This is the main remaining gap between broad `SpectecTerminal(s)` and
     ideal source-shaped Maude sorts.

Accepted representation choices for now:

- Source-star premises lower to source-style sequence judgements such as
  `Valtype-oks` and `Val-oks`; this is accepted as source `*` lowering, not a
  random shortcut.
- `$map-*`, `$valid-*`, `$result-*`, and `$cont-*` are source-derived execution
  views for source meta-expressions / source `def` conditions. They should be
  mentioned if professor asks how `def` execution is made equational, but the
  top-level non-isomorphism discussion should focus on the three items above.
- `$heaptype-sub?` / `$reftype-sub?` are source-derived decision mirrors used
  to make the reference/cast `-- otherwise` priority executable. Focused
  positive and negative probes pass, but this is still worth mentioning if the
  professor asks about source-absent execution guards.

## Current Execution Audit

The latest broad generated-rule concrete audit is:

```text
artifacts/rule-concrete-audit-20260525_004500/summary.md
```

Result:

```text
total rl/crl: 830
REDUCED: 559
STUCK: 271
STACK_OVERFLOW: 0
MAUDE_EXIT: 0
TIMEOUT: 0
```

Interpretation:

- `559 REDUCED`: these generated concrete commands did execute.
- `271 STUCK`: these commands did not reduce under the generated samples. This
  does not automatically mean each rule is broken; many samples lack the right
  source-valid context/store/module/type witness.
- `0 STACK_OVERFLOW`: the previous `infer-instrs-ok-arg0-r3` crash is gone.
  Non-productive self-recursive witness helpers are no longer generated.
- The rule count dropped from 835 to 830 because source-absent helper rules
  that only forwarded a recursive witness were pruned; SpecTec source rl/crl
  rules are still emitted.

The latest focused probe matrix is:

```text
artifacts/c1-probe-matrix-20260525_004421/probe_summary.md
```

Focused result:

- `43 PASS`
- `0 FAIL`
- `0 EXPECTED_STUCK`
- `0 STACK_OVERFLOW`

Focused passing probes include:

- sequence index probes;
- empty and multi result type validation;
- empty-arrow instruction type validation;
- `Instr-ok/nop`, `Instr-ok/unreachable`, `Instr-ok/local.get`;
- `Instrs-ok(CONST i32 0, arrow(...))`;
- `Expr-ok-const`;
- constant-expression `Global-ok`;
- `Val-oks` empty and multi-value validation;
- reference/cast `otherwise` positive and negative paths:
  `br_on_cast`, `br_on_cast_fail`, `ref.test`, `ref.cast`;
- `$evalexprs` one-const and `$evalexprss` one/two-const flat nonempty probes;
- `$infer-instrs-ok-arg0` frame empty-prefix termination smoke;
- `$invoke(...)` rewrites to a `Config`;
- source-shaped invoke outer-frame path:
  `steps(invoke-outer-config)` and `steps(fib-config-invoke(i32v(5)))`;
- label/br suffix search;
- br_if suffix search;
- nop suffix search;
- `steps(fib-config(i32v(5)))`.

## Known Execution Limitations

Current focused execution limitations:

1. **`infer-instrs-ok-arg0-r3`**
   - The previous stack overflow is blocked by pruning non-productive
     self-recursive `$infer-*` helper rules that only forward the same witness.
   - The source `Instrs_ok/frame` relation rule remains generated; only the
     source-absent witness overlay is reduced.
   - The focused termination smoke no longer crashes.
   - Arbitrary context witness synthesis is still not solved by the source; if
     a query asks only for a context with too little source information, it may
     remain stuck instead of inventing one.

2. **Nonempty `$evalexprss` / `expr**`**
   - The source uses nested sequence `expr**`.
   - Current Maude representation is mostly flat `SpectecTerminals`.
   - Empty and nonempty flat concrete probes now execute under `rew`.
   - True nested grouping, especially explicit empty inner groups, is still a
     representation question if benchmarks require it.

3. **Source-shaped invoke / outer-frame path**
   - Resolved for focused probes by source-derived empty-record
     canonicalization (`$empty-moduleinst`, `$empty-frame`, `$empty-store`).
   - `$invoke(...)`, `steps(invoke-outer-config)`, and
     `steps(fib-config-invoke(i32v(5)))` all reach the Fibonacci result.

4. **Builtin backend completeness**
   - `builtins.maude` implements the first concrete `hint(builtin)` layer for
     `$ibits`, `$inv-ibits`, `$irev`, `$lanes`, and `$inv-lanes`.
   - This is not a full SIMD/float/relaxed-numeric backend library yet.

## What To Ask Professor

Ask these before trying to make every rule execute:

1. Is C1 supposed to be a structural/isomorphic baseline with representative
   execution smokes, or must every generated rule have a source-valid concrete
   execution sample?
2. Can the 20 label-related `step-from-step-pure-*` shortcuts remain as
   temporary C1 executable debt, or must they move to a C2 execution layer?
3. Are generic witness helpers such as `$infer-*` acceptable in C1, or should
   witness synthesis be explicitly a C2 solver feature?
4. Should C1 implement typed/mixed/nested sequence sorts to remove remaining
   `$is-spectec-*` / `_hasType_` guards, or is the current broad-carrier
   representation acceptable for the baseline?
5. Can the source-derived `otherwise` decision guards for reference/cast paths
   remain in C1, or should that execution priority move to C2?

## Recommended Next Steps

Before moving to P4/generalization:

1. Review `docs/limitation.md` with professor.
2. Decide the C1 acceptance criterion: structural baseline vs full concrete
   executable coverage.
3. If professor wants stricter C1 execution, use the focused matrix as the
   executable baseline and next classify the broad concrete audit's remaining
   `NO_SOLUTION` samples by source-valid witness availability.
4. If professor accepts benchmark-driven execution, move on to benchmark
   selection and fix paths as benchmarks require them.
5. Keep init-config/frontend/model checking separate until explicitly resumed.

## Fresh Chat Prompt

Use this when starting a new Codex chat:

```text
You are working on my Spec2Maude C1 baseline.

Please first read:
- STATUS.md
- docs/limitation.md
- docs/HowToTest.md
- artifacts/rule-concrete-audit-20260525_004500/summary.md
- artifacts/c1-probe-matrix-20260525_004421/probe_summary.md

Current goal:
C1 is a faithful WebAssembly SpecTec-to-Maude baseline. Do not assume old
archive docs are current. Do not blindly edit translator_bs.ml.

Current non-isomorphic / professor-discussion items:
1. 20 label-related step-from-step-pure-* executable shortcuts.
2. $infer-* witness inference overlay.
3. Category / sequence representation gap: remaining $is-spectec-* and
   _hasType_ / WellTyped guards.

Current execution audit:
- 830 generated rl/crl tested by concrete rewrite audit.
- 559 REDUCED.
- 271 STUCK under generated samples.
- 0 STACK_OVERFLOW / MAUDE_EXIT / TIMEOUT.

Latest focused matrix:
- 43 PASS.
- 0 expected stuck.
- 0 stack overflow.

Before changing code, inspect current output_bs.maude, translator_bs.ml,
docs/limitation.md, and the latest artifacts listed above.
```
