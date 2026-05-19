# Spec2Maude C1 Status

Updated: 2026-05-20

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

Current accepted facts:

- `dune build ./main_bs.exe` passes.
- `dune exec ./main_bs.exe -- wasm-3.0/*.spectec > output_bs.maude` passes.
- `output_bs.maude` loads through `wasm-exec-bs.maude`.
- Standard Fibonacci execution regressions pass.
- The helper-heavy Module-ok / init-config experiment has been pruned or
  deferred from the active C1 baseline.
- Strict validation lowering structural audit is complete: 281 / 281 strict
  source-rule targets are emitted as primary Maude `rl` / `crl` rules.
- No derived validation rules remain: there are no generated `iter-empty` or
  `opt-empty` validation labels.
- Source-rule footer duplicates for `Expand`, `Num-ok`, and singleton `Val-ok`
  have been removed from the generator.
- Remaining `eq` / `ceq ... = valid` statements are footer / executable
  leftovers only: sequence-shaped `Val-ok` list-lifting for harness/prelude
  use.
- `translator_bs.ml` should not contain benchmark-specific or Wasm-judgement
  hardcoding such as:

```bash
grep -n "Func-ok\|Instrs-ok\|Module-ok\|Externaddr-ok\|fib\|CTORI32A0" translator_bs.ml
```

Expected result: no output.

## Strict Validation-Lowering Status

The strict validation-lowering audit is complete and documented in
`validation_281_summary.md`.

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

Known strict execution limitations are recorded in `limitation.md`. The main
categories are:

- empty `*` premises without derived `iter-empty` rules;
- `Instrs-ok/seq` witness synthesis;
- the strict single-rule `Step/ctxt-instrs` label/br suffix executability
  limitation;
- concrete store/harness lookup limitations;
- footer/prelude/genericity debt.

The footer `= valid` cleanup removed duplicate source-rule equations for
`Expand`, `Num-ok`, and singleton `Val-ok`. The remaining sequence-shaped
`Val-ok` equations are documented as non-C1-final harness/prelude debt in
`docs/c1-validation/footer_valid_leftovers_audit.md`.

Current next tasks:

1. Review `limitation.md` with the professor.
2. Decide whether witness synthesis / a mode-aware validation solver belongs
   in C1 or C2.
3. Continue `output_bs.maude` isomorphism cleanup.
4. Audit footer/prelude separation.
5. Keep init-config, frontend, and model checking out of the current C1 cleanup
   unless explicitly resumed.

## Important Files

- `translator_bs.ml`: active C1 translator. Final fixes must be made here.
- `output_bs.maude`: generated C1 output. Do not patch manually as final.
- `wasm-exec-bs.maude`: current execution/regression harness.
- `wasm-3.0/*.spectec`: WebAssembly 3.0 SpecTec source semantics.
- `validation_281_summary.md`: strict validation-lowering coverage summary.
- `limitation.md`: current strict C1 limitations and documented executable
  debt.
- `docs/c1-validation/`: detailed validation audit artifacts moved out of the
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
7. **Re-evaluate the `WasmTerm` / `WasmType` / typecheck infrastructure.** Do
   not delete Wasm object-language type syntax or SpecTec validation semantics.
   Instead distinguish:
   - object-language type syntax;
   - validation relation semantics;
   - runtime/execution typecheck or membership guards.

   If well-typed input programs are assumed, audit whether execution rules
   still need runtime typecheck/membership guards, and whether broad
   `WasmType` ground terms that never appear in actual programs/configurations
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

if all-vals(STEP-CTXT-INSTRS2-VALS)
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
eq all-vals(eps) = true .
ceq is-val(W) = true if W : Val .
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
split exists for terms such as `label(... br 0) local.get 1`; however Maude does
not combine that split with the conditional rewrite premise during full rule
application. Reordering the conditions to put the `Step` premise first caused
runaway recursion / stack overflow.

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
op step-pure : WasmTerminals -> StepPureConf [frozen (1)] .
op step-read : Config -> StepReadConf [frozen (1)] .
op steps     : Config -> StepsConf [frozen (1)] .
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

### `$invoke` reduces to a concrete config

```maude
red in WASM-FIB-BS :
  $invoke(fib-store, 0, i32v(5) i32v(0) i32v(1)) .
```

Expected/current result: a concrete `Config`, not a stuck `$invoke(...)`.

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

This path currently stops early at the known outer invoke frame/label/block
shape. `$invoke(...)` itself reduces to a concrete `Config`; the full
`fib-config-invoke` execution is a separate invoke-path issue.

## Completed Major Task: Strict Validation Rule Lowering

Validation judgement lowering is no longer the current structural blocker.
Source validation rules are no longer missing `rl` / `crl` lowering.

Current strict status:

- 281 / 281 strict source-rule targets are emitted as primary Maude `rl` /
  `crl` rules.
- No strict source target remains as `eq` / `ceq ... = valid`.
- No `iter-empty` or `opt-empty` derived validation labels remain.
- Source-rule footer duplicates for `Expand`, `Num-ok`, and singleton `Val-ok`
  have been removed from the generator.
- Remaining `eq` / `ceq ... = valid` statements are non-source footer /
  executable leftovers only: sequence-shaped `Val-ok` list-lifting for the
  current harness/prelude.

Selected concrete validation tests pass, but strict C1 does not claim that
every validation relation is executable by plain Maude rewriting. Remaining
validation issues are strict executability limitations documented in
`limitation.md`, especially empty `*` premises, `Instrs-ok/seq` witness
synthesis, and concrete store/harness lookup.

The next validation design decision is whether empty-star solving, witness
synthesis, or a mode-aware validation solver belongs in C1 or should be left to
C2.

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

## `WasmType` / Typecheck Infrastructure Audit

The current `WasmTerm` / `WasmType` / `is-type` / `are-types` framework may be
legacy or ad hoc. Audit before making invasive changes.

Clarifications:

- Do not delete Wasm object-language type syntax such as `i32`, `functype`,
  `heaptype`, or source-level annotations.
- Do not delete SpecTec validation semantics.
- Do distinguish object-language type syntax, validation relations, and runtime
  execution guards.

Audit questions:

- Where are `WasmType`, `is-type`, `are-types`, and `are-mixed` used?
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

Maude load warnings remain. Classify them later into:

- advisory / cosmetic;
- multiple distinct parses;
- used-before-bound.

Prioritize used-before-bound warnings in validation relations, because they may
be related to output-bearing premise scheduling and source-module initial-config
blockers.

## Next Concrete Tasks

Do not jump to frontend, model checking, or broad speculative infrastructure.

Recommended next tasks:

1. Review `limitation.md` with the professor.
2. Decide C1 vs C2 placement for witness synthesis / mode-aware validation
   solving, including empty-star cases.
3. Continue `output_bs.maude` isomorphism cleanup.
4. Audit footer/prelude separation, especially sequence-shaped `Val-ok`.
5. Keep init-config, frontend, and model checking out of the current C1 cleanup
   unless explicitly resumed.

Do not claim the final source-module path is complete until a validation-
preserving instantiated config can run to the Fibonacci result without bypasses.
