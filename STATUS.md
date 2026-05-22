# Spec2Maude C1 Status

Updated: 2026-05-22

This is the current handoff for the C1 baseline. Read this before continuing
translator work.

## Big Picture

Spec2Maude currently translates the WebAssembly 3.0 SpecTec semantics into a
Maude rewriting-logic specification.

The research goal is not merely to run one Fibonacci benchmark. The goal is to
build a faithful, relation-preserving SpecTec-to-Maude baseline that can later
be transformed into analysis-friendly semantics.

Project stages:

1. **C1**: faithful / relation-preserving SpecTec-to-Maude baseline.
2. **C2**: analysis-friendly transformation derived from C1.
3. **Evaluation**: rewrite/search/LTL experiments over C1/C2.

The active target is C1. Model checking is deferred until the baseline is
clean, documented, and stable.

## Current Accepted C1 Baseline

The active generated output is `output_bs.maude`, regenerated from
`translator_bs.ml`.

Regenerate with:

```bash
dune build ./main_bs.exe
dune exec ./main_bs.exe -- wasm-3.0/*.spectec > output_bs.maude
```

Run the current consolidated local regression with:

```bash
scripts/run_c1_regression.sh
```

That script rebuilds/regenerates, checks the strict invariants, runs the
isolated concrete probe matrix, inventories generated `rl` / `crl` labels, and
writes Maude logs plus warning classification under `artifacts/c1-regression-*`.

For the focused accepted C1 smoke/probe matrix, run:

```bash
python3 scripts/run_c1_probe_matrix.py
```

The latest focused matrix is
`artifacts/c1-probe-matrix-20260522_114516/`: 27 / 31 probes pass, and the
four remaining probes are expected stuck cases documented in
`docs/limitation.md`.

For the broad rule-level concrete execution audit over generated `rl` / `crl`,
run:

```bash
python3 scripts/audit_output_bs_rules_concrete.py --timeout 3
```

This generates an explicit concrete Maude command for every generated rule and
writes incremental results/logs under `artifacts/rule-concrete-audit-*`. The
latest completed rule audit is `artifacts/rule-concrete-audit-20260522_020812/`.
Its refined classification is
`artifacts/rule-concrete-classification-20260522_023538/`. This audit is a
concrete probe catalog, not a proof for all possible inputs.

Current accepted facts:

- `dune build ./main_bs.exe` passes.
- `dune exec ./main_bs.exe -- wasm-3.0/*.spectec > output_bs.maude` passes.
- `output_bs.maude` loads through `wasm-exec-bs.maude`.
- Standard Fibonacci execution regressions pass.
- The helper-heavy Module-ok / init-config experiment has been pruned or
  deferred from the active C1 baseline.
- Strict validation lowering structural audit is complete: 281 / 281 strict
  source-rule targets are emitted as primary Maude `rl` / `crl` rules.
- No old judgement-specific derived validation copies remain: there are no
  generated `iter-empty` or `opt-empty` validation labels.
- Source-rule footer duplicates for `Expand`, `Num-ok`, and singleton `Val-ok`
  have been removed from the generator.
- The sequence-shaped `Val-ok` footer list-lift has also been removed from the
  strict core.
- No `eq` / `ceq ... = valid` statements remain in `output_bs.maude`.
- The four known rule-label fidelity anomalies have been cleaned up:
  `Rectype_ok/_rec2`, `Fieldtype_sub/var`, `Globaltype_sub/var`, and
  `Instr_ok/if` now generate source-faithful Maude rule labels.
- Focused dead-helper cleanup removed `$cfg-state`, `$cfg-instrs`,
  `needs-label-ctxt`, `is-trap`, stale `VALOK-*` variables, and the disabled
  `ExecConf restore-*` generator branch without changing accepted execution
  smokes.
- The broad footer duplicate equations for `$local` and `$with-local` were
  removed; the source-generated definitions remain and accepted execution
  smokes still pass.
- The old footer sequence-lift overloads for `$subst-typeuse`,
  `$subst-valtype`, and `$subst-subtype` have been removed. Source element-level
  substitution defs remain, and source expressions such as `f(x*)` / `f(x)^n`
  now generate generic `$map-*` star-map helpers from the SpecTec AST shape
  instead of fixed footer strings.
- Generic sequence indexing for SpecTec meta-expressions `xs[i*]` is now
  emitted in the generated prelude. The concrete probes
  `index(CTORI32A0 CTORI64A0, eps)`,
  `index(CTORI32A0 CTORI64A0, 0 1)`, and
  `index(value('LOCALS, C), eps)` reduce, and
  `Instrtype-ok(C, arrow(i32, eps, i32))` rewrites to `valid`.
- Scalar sequence indexing now also closes out-of-bounds probes such as
  `index(CTORI32A0, 1)` to `eps`, avoiding the previous concrete-audit stack
  overflow on `index(eps, 0)`.
- Generated `$map-*` helpers now unfold only when `len(sequence) > 0` is
  operationally known, and terminal-valued source defs that embed Bool
  expressions now get generic Bool sort-safety conditions. This removes the
  previous vector bitmask stack overflow around `$ivbitmaskop` /
  `$vbitmaskop`; those terms now remain symbolic only because source
  `hint(builtin)` functions such as `$lanes`, `$inv-ibits`, and `$irev` do not
  yet have concrete backend implementations.
- Generic prefix-constructor star-map lowering is now emitted through
  `$star-prefix` / `$star-unprefix` for source shapes such as `(SET t)*`.
  The concrete probe
  `Instrtype-sub(C, arrow(i32, eps, i32), arrow(i32, eps, i32))` now rewrites
  to `valid` without judgement-specific helper rules.
- Generic relation-star lowering is now emitted as source-style sequence
  judgements such as `Valtype-oks`, `Valtype-subs`, and `Func-oks` for source
  premises of the form `(J(...))*`. The old internal `$iter-*` naming is gone.
  This fixes concrete
  probes such as `Resulttype-ok(C, eps)`,
  `Resulttype-sub(C, eps, eps)`,
  `Instrtype-ok(C, arrow(eps, eps, eps))`,
  `Instrtype-sub(C, arrow(eps, eps, eps), arrow(eps, eps, eps))`, and
  `Instr-ok/unreachable`.
- Source-derived category/sequence improvements now make the representative
  value-producing validation path execute: `Instrs-ok(CONST i32 0,
  arrow(eps, eps, i32))`, `Expr-ok-const(C, CONST i32 0, i32)`, and
  constant-expression `Global-ok` all pass in the focused probe matrix.
- Generated `$is-spectec-*` predicates now include a generic membership
  fallback, so typed opaque harness constants can satisfy category predicates
  when Maude already knows their membership sort.
- Zero-arity syntax constructors now get generated least sorts below all
  source categories they inhabit. This lets simple category variables such as
  `Numtype`, `Vectype`, and `Packtype` remain Maude-sorted in relation rules
  and removes the corresponding `$is-spectec-*` guards.
- A source-derived typed record layer is now generated from SpecTec `StructT`
  declarations. The output includes constructors such as `RECContextA13`,
  `RECStoreA10`, `RECModuleinstA9`, and `RECFrameA2`, plus generated
  projection, update, and typed merge equations. Unique source record shapes
  canonicalize from the generic `{item(...) ; ...}` DSL record form to the
  typed record constructor; ambiguous field shapes intentionally do not
  canonicalize automatically.
- Source-derived typed record field variables are now namespaced by record sort
  in generated projection/update/merge equations. This prevents different
  records that share field names, such as `taginst.TYPE` and `eleminst.TYPE`,
  from accidentally sharing one Maude variable sort. The focused
  `step-read-array-new-elem-alloc` probe now reduces through
  `value('REFS, $elem(...))` to the expected elem reference sequence.
- RelD lowering now preserves those source-derived record sorts on rule LHS
  variables. This removes binder-only record guards such as
  `$is-spectec-context`, `$is-spectec-store`, `$is-spectec-frame`, and
  `$is-spectec-moduleinst`. Representative source-unconditional rules such as
  `Instr_ok/nop` now generate unconditional Maude `rl`.
- Source-derived typed index lowering now handles flat composite sequence
  elements stored in source record fields. For source expressions such as
  `C.LOCALS[x]`, where `LOCALS` is a `localtype*` field and `localtype` is a
  composite element like `SET i32`, the generator emits
  `$typed-index(localtype, value('LOCALS, C), x)` instead of raw flat
  `index(...)`. This fixes the representative `Instr-ok/local.get` probe
  without localidx/localtype-specific hardcoding.
- Non-record sequence/composite categories such as `instr`, `expr`,
  `valtype`, and `idx` are intentionally still carried through the broad
  `SpectecTerminal`/`SpectecTerminals` substrate with generated membership predicates
  where needed. A direct attempt to narrow instruction sequence decomposition
  too aggressively caused Maude divergence on `Expr-ok-const`; this is recorded
  in `docs/archive/current-c1/record_sort_guard_removal_audit.md` and
  `docs/limitation.md`.
- A direct experiment confirmed that simply replacing `$is-spectec-context(C)`
  with a Maude-sorted LHS variable `C : Context` does not match broad
  `DSL-RECORD` literals. Broadly overloading `{_}` to return `Context` is
  unsound. The current `REC...` record path avoids that broad overload and is
  generated from source `StructT`; see
  `docs/archive/current-c1/record_sort_guard_removal_audit.md`.
- Generic LHS projection hoisting now handles source conclusions containing
  field projections, such as `Externaddr-ok(s, FUNC a, FUNC funcinst.TYPE)`.
  The concrete `Externaddr-ok(fib-store, FUNC 0, FUNC fib-type)` probe rewrites
  to `valid` without judgement-name or benchmark-specific logic.
- The finite type-iteration helpers `$rec-typevars`, `$def-typeuses`, and
  `$idx-typeuses` were audited as source-absent and unused; they were removed
  from the generator and regenerated output, with accepted execution smokes
  still passing.
- Header/pretype cleanup has started for P4/general SpecTec readiness. The
  legacy fixed `w-N` / `w-M` / ... / `w-E` `SpectecType` constants and the unused
  header `_ =++ _` declaration were removed. The old hardcoded
  `Nat < Labelidx` / `Nat < Localidx` / `Nat < Addr`-style list is now emitted
  from the SpecTec source alias graph instead of a fixed Wasm-name list.
- The active generated `output_bs.maude` no longer depends on
  `load dsl/pretype`. `translator_bs.ml` emits the generic `DSL-TERM`,
  `DSL-PRETYPE`, and `DSL-RECORD` modules directly into the generated output.
  The checked-in `dsl/pretype.maude` is currently a legacy/reference copy, not
  the active C1 dependency.
- The generated header/footer is now partially feature-gated from the source
  and generated body. Header pieces such as `w-bool`, `WellTyped`/`hasType`,
  sequence-index/star/slice helpers, set-membership, merge/any, Step wrappers,
  and source sequence-category predicates are emitted only when the current spec
  output uses them. The old frame-specific footer shim was removed: frame
  literals now use the source-derived `RECFrameA2` record constructor and its
  generated projection/update equations. This does not remove the generic
  `SpectecTerminals` carrier yet, but it cuts another layer of fixed
  Wasm-oriented header/footer output for future P4/general SpecTec experiments.
- A broader attempt to derive every `CTOR...` operator signature directly from
  source syntax was tested and rejected for now: it introduced Maude
  preregularity warnings, caused `$expanddt` to get stuck, and made Fibonacci
  execution stack overflow. The three execution-critical label/frame/handler
  CTOR signatures therefore remain explicitly overridden until a safer
  source-derived signature scheme is designed.
- The first warning cleanup pass removed the Maude
  `assignment condition fragment ... bound before matching` advisory family by
  emitting equality checks when a premise no longer binds new variables. The
  second pass added generic `ListN` length binding for RelD rules, fixing the
  `deftype-ok-r0` length-variable warning from source patterns such as
  `rectype = REC subtype^n`. The next warning pass fixed source
  category-pattern disjunctions such as `t' = numtype \/ t' = vectype` by
  lowering them to generated Bool category predicates, and fixed DecD `TypA`
  argument lowering so type parameters such as `$concat_(N, ...)` no longer
  leave raw unbound `N` in generated helper conditions. The latest warning pass
  removed `multiple distinct parses` by printing arithmetic, Bool, comparison,
  and generated `$map-*` helper expressions with explicit Maude prefix
  operators. The remaining warning families are documented in
  `docs/limitation.md`.
- `translator_bs.ml` should not contain benchmark-specific or Wasm-judgement
  hardcoding such as:

```bash
grep -n "Func-ok\|Instrs-ok\|Module-ok\|Externaddr-ok\|fib\|CTORI32A0" translator_bs.ml
```

Expected result: no output.

## What To Read

Use `docs/limitation.md` as the single current summary of C1 limitations and
remaining debt. The many files under `docs/archive/` are detailed audit
evidence, not required reading for ordinary continuation work.

Minimal reading order:

1. `docs/limitation.md`: current truth for limitations and accepted/deferred debt.
2. `STATUS.md`: commands, handoff state, and next tasks.
3. `docs/HowToTest.md`: manual Maude smoke tests.

## Strict Validation-Lowering Status

The strict validation-lowering audit is complete. A detailed historical summary
is archived at `docs/archive/validation_281_summary.md`; the current limitation
summary is `docs/limitation.md`.

Structural coverage:

| Source file / family | Strict targets | Primary rl/crl matched |
|---|---:|---:|
| `wasm-3.0/2.1-validation.types.spectec` | 42 | 42 |
| `wasm-3.0/2.2-validation.subtyping.spectec` | 50 | 50 |
| `wasm-3.0/2.3-validation.instructions.spectec` | 140 | 140 |
| `wasm-3.0/2.4-validation.modules.spectec` | 28 | 28 |
| `wasm-3.0/4.1-execution.values.spectec` + `Eval_expr` | 21 | 21 |
| **Total** | **281** | **281** |

Concrete tests passed for selected leaf/simple validation judgements, including
representative type validation, subtyping, instruction validation, module leaf
validation, value validation, and `Eval_expr` probes.

Known strict execution limitations are recorded in `docs/limitation.md`. The
main categories are:

- label-related `step-from-step-pure-*` 20 shortcuts retained as non-C1-final
  executable debt;
- `$infer-*` generic witness overlay, which needs a C1/C2 boundary decision;
- source-style relation-star lowering (`Valtype-oks` and related helpers) is
  now treated as accepted lowering for SpecTec `*` meta-notation, not as a
  separate non-isomorphic debt item;
- remaining category/sequence representation guards (`$is-spectec-*` /
  `_hasType_`) where source categories are not yet fully represented as Maude
  typed sequence sorts;
- sequence-shaped direct `Val-ok` queries after removing the old non-source
  list-lift footer helper;
- broader typed/mixed sequence sort design; the representative composite
  record-field index case `C.LOCALS[0] = SET i32` is now handled by
  source-derived `$typed-index`, but `_hasType_` / `$is-spectec-*` guards still
  remain for categories that cannot yet be represented as precise Maude
  sequence sorts;
- invoke/init-config path limitations, especially `steps(fib-config-invoke(...))`;
- broad rule-audit rows that need source-valid runtime/module/type contexts
  before they can be treated as real bugs.

The footer `= valid` cleanup removed duplicate source-rule equations for
`Expand`, `Num-ok`, singleton `Val-ok`, and the non-source sequence-shaped
`Val-ok` list-lift. The current strict output has no `eq` / `ceq ... = valid`
leftovers; the removed sequence probes are documented in
`docs/archive/c1-validation/footer_valid_leftovers_audit.md` and
`docs/limitation.md`.

Current next tasks:

1. Review `docs/limitation.md` with the professor.
2. Continue warning cleanup only for source-preserving fixes: especially
   remaining `used-before-bound` witness cases. Precedence-related
   `multiple distinct parses` are currently removed.
3. Decide whether the new `$infer-*` / `-exec-tail-empty*` validation execution
   overlay is acceptable in C1, or whether it should move to C2.
4. Continue `output_bs.maude` isomorphism cleanup.
5. Continue footer/prelude separation one family at a time. The first dead
   helper cleanup, the `$local` / `$with-local` footer-shim cleanup, and the
   `$subst-*` footer sequence-lift cleanup have passed. Remaining cleanup
   candidates include `EXP`, source-driven feature detection instead of
   generated-text scans, and a safer source-derived CTOR signature scheme.
6. Keep init-config, frontend, and model checking out of the current C1 cleanup
   unless explicitly resumed.

## Important Files

- `translator_bs.ml`: active C1 translator. Final fixes must be made here.
- `output_bs.maude`: generated C1 output. Do not patch manually as final.
- `wasm-exec-bs.maude`: current execution/regression harness.
- `wasm-3.0/*.spectec`: WebAssembly 3.0 SpecTec source semantics.
- `docs/limitation.md`: single current summary of strict C1 limitations and
  documented executable debt.
- `docs/archive/validation_281_summary.md`: archived strict validation-lowering
  coverage summary.
- `docs/archive/c1-validation/`: detailed validation audit artifacts moved out of the
  repository root.
- `translator.ml`, `output.maude`, `wasm-exec.maude`: older/reference path;
  do not mix into C1 unless explicitly comparing with legacy behavior.

## Professor Requirements from 2026-05-19 Meeting

These are C1 design constraints.

1. **Preserve C1 as the faithful SpecTec-to-Maude baseline.** C1 should show
   that SpecTec syntax, definitions, and relation rules can be translated as
   directly as possible. Model checking and analysis-oriented transformations
   belong to later phases.
2. **Use clear variable naming for singleton vs sequence variables.** A
   singleton `instr` should be visibly different from `instr*`; use names such
   as `INSTR` and `INSTRS`.
3. **Remove redundant Boolean wrappers where Maude accepts Bool conditions
   directly.** Generated conditions should avoid wrappers such as `(C =/= 0) =
   true` when `C =/= 0` is accepted.
4. **Translate SpecTec `rule` / relation judgements as Maude `rl/crl` as much
   as possible.** The strict validation-lowering structural audit is complete:
   281 / 281 strict source-rule targets now lower to primary Maude `rl` /
   `crl`. Remaining validation issues are executability limitations, not
   missing source-rule lowering.
5. **Avoid helper-heavy executable shortcuts.** Any remaining scaffold must be
   generic, justified, and documented. Benchmark-specific or Wasm-judgement-name
   hacks do not belong in `translator_bs.ml`.
6. **Grow the work from Wasm-to-Maude toward generic SpecTec-to-Maude.** Audit
   Wasm-specific names/hardcoding, try non-Wasm SpecTec inputs such as
   `p4-spectec`, and identify unsupported frontend/spec features.
7. **Re-evaluate the `WasmTerm` / `SpectecType` / typecheck infrastructure.** Do
   not delete Wasm object-language type syntax or SpecTec validation semantics.
   Instead distinguish:
   - object-language type syntax;
   - validation relation semantics;
   - runtime/execution typecheck or membership guards.

   If well-typed input programs are assumed, audit whether execution rules
   still need runtime typecheck/membership guards, and whether broad
   `SpectecType` ground terms that never appear in actual programs/configurations
   unnecessarily pollute the syntax universe.
8. **Check broad coverage.** Verify all relevant Wasm SpecTec documents and use
   non-Wasm smoke-test failures as evidence of current genericity limitations.
9. **Prepare professor-facing mapping evidence.** Document how syntax
   declarations, definitions, relation rules, and representative execution
   relations map into Maude.

## Current Cleanup State

### Completed: singleton vs sequence variable naming

Generated Maude variables now distinguish singleton terms from star/list terms.
Examples:

```text
instr    -> INSTR
instr*   -> INSTRS
instr'   -> INSTRQ
instr'*  -> INSTRSQ
val*     -> VALS
```

Representative generated rules now use sequence-variable names such as
`STEP-PURE0-INSTRS`, `STEP-PURE0-INSTRSQ`,
`STEP-CTXT-INSTRS2-VALS`, `STEP-CTXT-INSTRS2-INSTRS`, and
`STEP-CTXT-INSTRS2-INSTRSQ`.

This is a naming/readability cleanup only. It should not change semantics.

### Completed: Boolean condition wrapper cleanup

Generated Maude conditions now use Bool terms directly instead of wrapping
condition fragments as `(B) = true`.

Examples of cleaned forms:

```maude
if STEP-PURE-BR-IF-TRUE11-C =/= 0 .

if $is-spectec-val-seq(STEP-CTXT-INSTRS2-VALS)
/\ ((STEP-CTXT-INSTRS2-VALS =/= eps) or
    (STEP-CTXT-INSTRS2-INSTRS1 =/= eps))
/\ step((STEP-CTXT-INSTRS2-Z ; STEP-CTXT-INSTRS2-INSTRS))
   => (STEP-CTXT-INSTRS2-ZQ ; STEP-CTXT-INSTRS2-INSTRSQ) .
```

Checks that should remain true:

```bash
grep -n "if .* = true" output_bs.maude
grep -n "== valid = true" output_bs.maude
```

Expected result: no output.

Boolean function definitions such as these should remain:

```maude
eq $is-numtype(CTORI32A0) = true .
eq $is-spectec-val-seq(eps) = true .
ceq $is-spectec-val-seq(W TS) = $is-spectec-val-seq(TS) if W : Val .
```

They are definitions, not redundant condition wrappers.

### Completed: empty-result split cleanup

The following generated empty-result split rules are removed:

- `step-ctxt-instrs-empty`;
- `step-pure-empty`;
- `step-read-empty`;
- `step-ctxt-label-empty`;
- `step-ctxt-handler-empty`.

The corresponding bridge/context rules now handle both `eps` and non-`eps`
inner results in a single rule.

### Completed: remove non-label `step-from-step-pure-*` shortcuts

Audit result: `step-from-step-pure-*` rules are derived lifted shortcuts from
`Step_pure` into `Step`. They are not direct translations of original SpecTec
`Step` rules.

Current state:

- non-label `step-from-step-pure-*` shortcuts are removed;
- label-related `step-from-step-pure-*` shortcuts remain temporarily;
- the remaining label-related shortcuts are documented non-C1-final debt.

Reason for temporary retention: without them, the strict single-rule translation
of `Step/ctxt-instrs` is structurally faithful, and the intended associative
split exists for terms such as `label(... br 0) local.get 1`; however the
inner generic `step-pure` bridge does not produce
`step((Z ; label(... br 0))) => (Z ; eps)` operationally. The direct
`step-pure(label(... br 0)) => eps` rewrite succeeds, but the generated bridge
condition with a `SpectecTerminals` result variable does not bind the collapsed
`eps` result. Reordering the conditions to put the `Step` premise first caused
runaway recursion / stack overflow, and broadening the result to `StepPureConf`
admitted zero-step unreduced `step-pure(...)` terms.

Future work: remove the remaining label-related shortcuts by finding a faithful
generic context-closure encoding for C1, or move execution-oriented control
infrastructure to C2.

## C1 Relation Structure to Preserve

C1 must preserve these SpecTec relations:

```spectec
relation Step      : config ~> config
relation Step_pure : instr* ~> instr*
relation Step_read : config ~> instr*
relation Steps     : config ~>* config
```

Generated Maude must expose these public wrappers:

```maude
op step      : Config -> StepConf [frozen (1)] .
op step-pure : SpectecTerminals -> StepPureConf [frozen (1)] .
op step-read : Config -> StepReadConf [frozen (1)] .
op steps     : Config -> StepsConf .
```

`steps` is unary:

```maude
steps(C) => C'
```

Config syntax uses:

```maude
_ ; _
```

## Current Regression Evidence

Run through `wasm-exec-bs.maude`.

### `$expanddt` works

```maude
red in WASM-FIB-BS :
  $expanddt(value('TYPE, fib-funcinst)) .
```

Expected/current result:

```maude
CTORFUNCARROWA2(CTORI32A0 CTORI32A0 CTORI32A0, CTORI32A0)
```

### `$invoke` rewrites to a concrete config

```maude
rew [100] in WASM-FIB-BS :
  $invoke(fib-store, 0, i32v(5) i32v(0) i32v(1)) .
```

Expected/current result: a concrete `Config`, not a stuck `$invoke(...)`.
`red $invoke(...)` is not the right probe for this rule because it only performs
equational normalization; `$invoke` is discharged by rewriting.

### Focused one-step/context searches pass

- label/br + suffix search: exactly one `Config` solution.
- br_if + suffix search: exactly one `Config` solution.
- nop + suffix search: exactly one `Config` solution.

### Hand-assembled Fibonacci config executes

```maude
rew [10000] in WASM-FIB-BS :
  steps(fib-config(i32v(5))) .
```

Expected/current final result:

```maude
(fib-store ; empty-frame) ; CTORCONSTA2(CTORI32A0, 5)
```

### Known invoke-path issue

```maude
rew [10000] in WASM-FIB-BS :
  steps(fib-config-invoke(i32v(5))) .
```

This path currently stops at `steps($invoke(...))`. `$invoke(...)` itself
rewrites to a concrete `Config`; when that config is tested directly, the
source-shaped outer frame path exposes the separate `Step/ctxt-frame`
composition issue.

## Completed Major Task: Strict Validation Rule Lowering

Validation judgement lowering is no longer the current structural blocker.
Source validation rules are no longer missing `rl` / `crl` lowering.

Current strict status:

- 281 / 281 strict source-rule targets are emitted as primary Maude `rl` /
  `crl` rules.
- No strict source target remains as `eq` / `ceq ... = valid`.
- No old judgement-specific `iter-empty` or `opt-empty` derived validation
  labels remain.
- Source-rule footer duplicates for `Expand`, `Num-ok`, and singleton `Val-ok`
  have been removed from the generator.
- The sequence-shaped `Val-ok` footer list-lift has also been removed from the
  strict core.
- No `eq` / `ceq ... = valid` statements remain in `output_bs.maude`.

Selected concrete validation tests pass, but strict C1 does not claim that
every validation relation is executable by plain Maude rewriting. Remaining
validation issues are strict executability / overlay-design questions
documented in `docs/limitation.md`, especially whether the generic witness
execution overlay belongs in C1 or C2, direct sequence `Val-ok` list probes,
and invoke-path `$invoke` under `steps` plus `Step/ctxt-frame` composition
around source-shaped record frames.

The next validation design decision is whether the `$infer-*` / `$exec-*`
witness overlay is acceptable in C1, or whether it should be left to C2.

## Source-Level Initial Config Requirement

The professor-facing story cannot remain:

```text
manual fib-store / fib-funcinst / fib-moduleinst
  -> hand-assembled runtime config
  -> steps(...)
```

The intended story is:

```text
wasm / wat code
  -> Wasm module Maude term
  -> validation-preserving initial config generation
  -> generated C1 semantics
  -> steps / search / verification
```

Possible C1 target after the current strict limitations are reviewed:

```text
fib-module Maude term
  -> Module-ok / instantiate
  -> invoke
  -> unary steps(Config)
```

The benchmark harness may mention Fibonacci-specific names. The translator must
not.

## Generic SpecTec Direction

C1 should be audited as a generic SpecTec-to-Maude translator, not merely a
Wasm-specific executor.

Current `p4-spectec` smoke-test status:

```bash
dune exec ./main_bs.exe -- p4-spectec/*/*.watsup > output_bs_p4.maude
```

Current result: mostly parser/frontend failures such as `syntax error:
unexpected token` or `malformed token`; a few files parse, but elaboration then
fails with undeclared syntax such as `typedExpressionIR`, likely because
prerequisite files failed to parse.

Interpretation: the current frontend supports the Wasm SpecTec dialect/subset,
but is not yet a generic parser for P4 `.watsup` syntax. This is useful
limitation evidence for future generic SpecTec-to-Maude work, not a blocker for
current Wasm C1 cleanup.

## `SpectecType` / Typecheck Infrastructure Audit

The old hand-written `dsl/pretype.maude` typecheck predicates
`is-type`, `are-types`, and `are-mixed` have been removed from the current C1
prelude because generated `output_bs.maude` no longer uses them. `SpectecType` /
`SpectecTypes` still remain as the broad category/type witness substrate and should
be audited before making invasive changes.

The latest header cleanup also removed unused fixed `w-*` type constants from
the generated header and replaced the fixed Wasm index/address Nat-subsort list
with source-derived alias analysis. `SpectecTerminal`, `SpectecTerminals`,
`SpectecType`, `SpectecTypes`, `Judgement`, `valid`, and the step wrapper sorts still
remain as current Maude representation substrate.

The generated C1 output now includes its own generic prelude modules instead of
loading `dsl/pretype.maude`. This is a first step toward P4/general SpecTec
support: the prelude is still a generic Maude encoding chosen by the translator,
but it is no longer an external hand-written Wasm-named dependency.

The generated prelude is now split into feature-oriented pieces. `DSL-RECORD`
is emitted only when the scanned source uses source record/`StructT` shapes.
`DSL-PRETYPE` / `SpectecTerminals` is still emitted as the common term-sequence
carrier because the current translator represents SpecTec terminal lists through
that substrate.

Clarifications:

- Do not delete Wasm object-language type syntax such as `i32`, `functype`,
  `heaptype`, or source-level annotations.
- Do not delete SpecTec validation semantics.
- Do distinguish object-language type syntax, validation relations, and runtime
  execution guards.

Audit questions:

- Where are `SpectecType` and `SpectecTypes` still used?
- Are they used in execution rules, validation rules, or only generated
  membership/typecheck scaffolding?
- For already validated / well-typed input programs, do execution rules still
  need runtime typecheck or membership guards?
- Are ground type terms generated that cannot appear in actual programs or
  runtime configurations?
- Would a more elegant design use necessary syntax categories and Maude sorts
  rather than a broad type-tag framework?

## Design Constraints

Do not add any of the following to C1:

- `mc`;
- `exec-step`;
- `focused-step`;
- `dstep`;
- C2-style execution adapters;
- benchmark-specific rewrite rules;
- output-level manual patches as final;
- global `mb/cmb` to `$typed` conversion;
- deletion of `OpTerminal`, `InstrTerminals`, or `ValTerminals`;
- binary `steps`;
- validation premise bypasses.

Do not make execution pass by weakening or removing validation premises such as:

```maude
Module-ok(...)
Externaddr-ok(...)
Val-ok(...)
```

## Warning Cleanup

Current `load wasm-exec-bs` warning status after the current cleanup passes:

- assignment-fragment advisory: removed.
- used-before-bound: 10 total in the latest `scripts/run_c1_regression.sh`
  warning classification. Generic bugs fixed so far include `ListN`
  length binding for `deftype-ok-r0`, category-pattern disjunction lowering for
  `t' = numtype \/ t' = vectype`, and DecD `TypA` parameter lowering for
  `$ivadd-pairwise`. The remaining cases are mostly validation witness
  synthesis and execution/module helper output witnesses.
- multiple distinct parses: removed. Arithmetic, Bool, comparison, category
  disjunction, unary minus, and generated `$map-*` helper expressions now print
  with explicit Maude prefix operators where needed.
- command-time membership warnings: `load ... ; q` does not show the old
  membership warning family, but actual `red/search` smoke commands can still
  print 11 Maude builtin/pretype associative membership warnings plus one
  source-sequence `Nonfuncs` collapse advisory. Current smoke results are
  normal; defer this to typed sort/category cleanup.
- duplicate-import-advisory: removed. `Nat < SpectecTerminal` now lives in
  `DSL-PRETYPE`, and the record/list update operator keeps only the
  `SpectecTerminal` index declaration. Nat-index updates still work through the
  subsort.

`scripts/run_c1_regression.sh` writes a warning classification CSV. Treat each
remaining warning family as a separate source-preserving scheduling or
pretty-printing question rather than deleting premises or blindly changing
assignment fragments.

## Latest Focused Failure Triage

The 19 high-risk `STACK_OVERFLOW` / `MAUDE_EXIT_2` / `TIMEOUT` cases from the
total concrete audit were rechecked with source-shaped focused probes.

- `$concatn` stack overflow was a generic `ListN` lowering bug and is fixed.
- `clos-deftypes-r1`, `alloctypes-r1`, and
  `step-read-array-new-elem-alloc` are no longer considered real
  `MAUDE_EXIT_2` generator failures; the previous failures came from malformed
  or overly strict automatic samples.
- `$ivbitmaskop` / `$vbitmaskop` no longer stack overflow after generic
  expression-star and fixed-repeat lowering. They still remain a focused
  execution limitation because inverse hints such as `$ibits` /
  `$inv_ibits` and vector builtins such as `$lanes` are not yet fully
  operational in the generated Maude prelude.
- `evalexprss-r1` remains a nested-sequence representation limitation for
  `expr**`. Focused probing also showed that the underlying `$evalexprs`
  premise needs output witnesses from `Eval-expr`; exact-output `Eval-expr`
  reduces to `valid`, but Maude rewriting does not synthesize `ZQ/ref` outputs
  from `Eval-expr(..., ZQ, ref) => valid`. A temporary direct-`steps`
  unfolding works for concrete probes but is not strict C1-final.
- The remaining label/handler/return `Step_pure` and selected `Step_read`
  cases from the broad audit now pass with source-valid focused probes.
- `step-read-br-on-cast-succeed` is fixed. The generic Maude-variable extractor
  no longer treats mixed-case record constructors such as `RECContextA13` as fake
  variables, so the generated condition now gets `rt` from `Ref-ok` and then
  checks `Reftype-sub(empty-context, rt, target)`.
- `step-read-br-on-cast-fail-fail` remains an otherwise/negative-premise
  limitation: the false cast path needs the succeeding cast premise to fail
  cleanly, but Maude can recurse through subtype search instead.
- `infer-instrs-ok-arg0-r3` remains a context-witness synthesis limitation:
  the helper is asked to infer a context from `instr*` and an instruction type,
  but the source does not define a canonical context to choose.

Current dangerous-status summary:

- Most broad audit failures are sample bugs: source-valid focused probes pass.
- 2 generic translator bugs fixed: source-derived record field variable
  namespace, and mixed-case constructor variable extraction.
- 3 real limitations remain:
  `evalexprss-r1`, `step-read-br-on-cast-fail-fail`,
  `infer-instrs-ok-arg0-r3`.

Latest focused probe log:
`artifacts/phase1-error-triage-20260522_102830/summary.md`.
Latest regression log:
`artifacts/c1-regression-20260522_100049/`.

## Next Concrete Tasks

Do not jump to frontend, model checking, or broad speculative infrastructure.

Recommended next tasks:

1. Review `docs/limitation.md` with the professor.
2. Decide C1 vs C2 placement for the `$infer-*` / `-exec-tail-empty*`
   validation execution overlay.
3. Continue `output_bs.maude` isomorphism cleanup.
4. Audit footer/prelude separation now that `= valid` footer leftovers are gone.
5. Keep init-config, frontend, and model checking out of the current C1 cleanup
   unless explicitly resumed.

Do not claim the final source-module path is complete until a validation-
preserving instantiated config can run to the Fibonacci result without bypasses.
