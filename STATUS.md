# Spec2Maude C1 Status

Updated: 2026-05-19

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
- `translator_bs.ml` should not contain benchmark-specific or Wasm-judgement
  hardcoding such as:

```bash
grep -n "Func-ok\|Instrs-ok\|Module-ok\|Externaddr-ok\|fib\|CTORI32A0" translator_bs.ml
```

Expected result: no output.

## Important Files

- `translator_bs.ml`: active C1 translator. Final fixes must be made here.
- `output_bs.maude`: generated C1 output. Do not patch manually as final.
- `wasm-exec-bs.maude`: current execution/regression harness.
- `wasm-3.0/*.spectec`: WebAssembly 3.0 SpecTec source semantics.
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
   as possible.** Validation judgements currently lowered as `eq/ceq ... =
   valid` are a major remaining policy issue.
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

## Current Major Blocker: Validation Rule Lowering

The next major C1 task is validation judgement lowering.

Current generated validation rules such as `Module-ok`, `Func-ok`, `Instrs-ok`,
`Instr-ok`, `Types-ok`, and related judgements are still generated as equations:

```maude
eq  J(...) = valid .
ceq J(...) = valid if ... .
```

Professor requirement: SpecTec `rule` / relation judgements should be lowered
as Maude `rl/crl` as much as possible.

This cannot be solved by blindly replacing `eq/ceq` with `rl/crl`. Current
callers often use equation-style conditions such as:

```maude
J(...) == valid
```

If a callee is converted to a rewrite rule, caller premises may also need to be
translated to rewrite conditions:

```maude
J(...) => valid
```

Therefore this task needs dependency-aware audit before code changes.

Recommended next audit:

1. List all validation judgements generated as `eq/ceq ... = valid`.
2. For each family, record which other validation judgements it calls.
3. Identify self-recursion and mutual recursion.
4. Identify which caller families rely on `J(...) == valid`.
5. Find the smallest closed subset for a safe `rl/crl` prototype.
6. Only then implement a small prototype.

Important families:

```text
Module-ok
Func-ok
Expr-ok
Instrs-ok
Instr-ok
Types-ok
Locals-ok
Globals-ok
Tables-ok
Mems-ok
Elem-ok
Data-ok
Import-ok
Export-ok
Ref-ok
Externaddr-ok
subtype/type validation judgements
```

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

Immediate C1 target after validation policy is clarified:

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

## Next Concrete Task

Do not jump to frontend, model checking, or broad speculative infrastructure.

Next task:

```text
Validation rule-lowering audit:
why are Module-ok / Func-ok / Instrs-ok / related relation judgements emitted
as eq/ceq = valid instead of rl/crl, and what dependency closure is needed to
change them safely?
```

Useful starting commands:

```bash
grep -nE "^(  )?(eq|ceq) (Module-ok|Func-ok|Instrs-ok|Instr-ok|Types-ok)" output_bs.maude | head -80
grep -n "use_rewrite_judgement" translator_bs.ml
grep -n "translate_reld" translator_bs.ml
grep -n "is_rewrite_judgement_rel" translator_bs.ml
```

Useful acceptance ladder after validation work begins:

```maude
red in WASM-FIB-BS :
  Instrs-ok(
    {item('TYPES, eps) ; item('RECS, eps) ; item('TAGS, eps) ;
     item('GLOBALS, eps) ; item('MEMS, eps) ; item('TABLES, eps) ;
     item('FUNCS, eps) ; item('DATAS, eps) ; item('ELEMS, eps) ;
     item('LOCALS, eps) ; item('LABELS, eps) ; item('RETURN, eps) ;
     item('REFS, eps)},
    CTORCONSTA2(CTORI32A0, 0),
    CTORARROWA3(eps, eps, CTORI32A0)) .

red in WASM-FIB-BS :
  Module-ok(fib-module, CTORARROWA2(eps, eps)) .

red in WASM-FIB-BS :
  Externaddr-ok(empty-store, eps, eps) .

rew [1] in WASM-FIB-BS :
  $instantiate(empty-store, fib-module, eps) .
```

Do not claim the final source-module path is complete until a validation-
preserving instantiated config can run to the Fibonacci result without bypasses.
