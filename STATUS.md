# Spec2Maude C1 Status

Updated: 2026-05-19

This is the current handoff for the C1 baseline. Read this before continuing
translator work.

## Big Picture

Spec2Maude translates WebAssembly 3.0 SpecTec semantics into Maude.

The long-term research goal is not just to run one Fibonacci benchmark. The
goal is to translate SpecTec semantics as relation-preservingly and
isomorphically as possible, while still producing executable Maude semantics.

Project stages:

1. C1: faithful relation-preserving SpecTec-to-Maude baseline.
2. C2: analysis-friendly transformation derived from C1.
3. Evaluation: rewrite/search/LTL model-checking experiments comparing C1/C2.

The active target is still C1.

## Temporary Executable Scaffolding

`translator_bs.ml` currently restores only label-related generated
`step-from-step-pure-*` rules for executability. These rules are derived lifted
shortcuts from `Step_pure` into `Step`; they are not direct translations of
original SpecTec `Step` rules and are not C1-final. Non-label
`step-from-step-pure-*` shortcuts are intentionally suppressed.

The strict version without these shortcuts exposed a Maude executability
limitation in the single, SpecTec-shaped `Step/ctxt-instrs` rule: the intended
associative split exists for terms such as `label(... br 0) local.get 1`, and
each condition succeeds individually, but Maude does not combine that split with
the conditional rewrite premise during full rule application. Reordering the
conditions to put the `Step` premise first caused runaway recursion / stack
overflow.

Future work: remove the remaining label-related `step-from-step-pure-*`
shortcuts by finding a faithful generic context-closure encoding for C1, or
move execution-oriented control infrastructure to C2.

## C1 Goal

C1 is the relation-preserving baseline. It is not the C2 analysis-friendly
semantics and must not contain benchmark-specific execution adapters.

C1 must preserve the SpecTec relation structure:

```spectec
relation Step      : config ~> config
relation Step_pure : instr* ~> instr*
relation Step_read : config ~> instr*
relation Steps     : config ~>* config
```

Generated Maude must keep the public wrappers:

```maude
op step      : Config -> StepConf [frozen (1)] .
op step-pure : WasmTerminals -> StepPureConf [frozen (1)] .
op step-read : Config -> StepReadConf [frozen (1)] .
op steps     : Config -> StepsConf [frozen (1)] .
```

`steps` must remain unary:

```maude
steps(C) => C'
```

Config syntax must remain:

```maude
_ ; _
```

## Professor Requirements from 2026-05-19 Meeting

These requirements summarize the latest professor guidance and should be treated as C1 design constraints.

1. **Preserve C1 as the faithful SpecTec-to-Maude baseline.** Model checking and analysis-oriented transformations belong to later phases. C1 should first show that SpecTec syntax/defs/rules can be translated faithfully and relation-preservingly.
2. **Use clear variable naming for singleton vs sequence variables.** Starred SpecTec categories such as `instr*` should be visibly distinguished from singleton categories such as `instr`; prefer conventions such as `INSTR` for one instruction and `INSTRS` for instruction sequences.
3. **Remove redundant Boolean wrappers where Maude permits it.** Generated conditions like `(C =/= 0) = true` should be audited and simplified when a direct Boolean condition is accepted by Maude. Do not perform an unsafe blind global deletion without testing representative conditions.
4. **Translate SpecTec `rule`/relation judgements as Maude `rl/crl` as much as possible.** Validation judgements currently generated as `eq/ceq ... = valid` are a major policy issue and need dependency-aware redesign, not helper-heavy bypasses.
5. **Avoid helper-heavy executable shortcuts.** Any remaining scaffold must be generic, justified, and documented. Benchmark-specific or Wasm-judgement-name-specific hacks do not belong in `translator_bs.ml`.
6. **Grow the baseline from Wasm-to-Maude toward generic SpecTec-to-Maude.** Audit and remove Wasm-specific hardcoding; try non-Wasm SpecTec inputs such as `p4-spectec`; generalize names such as `WasmTerminal`/`WasmType` where appropriate.
7. **Re-evaluate the legacy `WasmTerm`/`WasmType` and typecheck infrastructure.** This does not mean deleting Wasm object-language type syntax or deleting validation semantics. The task is to distinguish object-language type syntax, validation relations, and runtime execution guards. If a well-typed input program is assumed, audit whether execution rules still need runtime typecheck or membership guards, and whether broad `WasmType` ground terms that never appear in actual programs/configurations are unnecessary syntax-universe pollution. Keep only an elegant, necessary sort/type framework.
8. **Check broad coverage.** Verify all relevant Wasm SpecTec documents, including non-core pieces if present, and use failures to identify translator limitations. Generic SpecTec smoke tests are useful even if full support is future work.
9. **Prepare professor-facing mapping evidence.** Show how syntax declarations, defs/equations, relation rules, and representative `Step`/`Step_pure`/`Step_read`/`Steps` rules map into Maude.

## Professor-Facing Initial-Config Requirement

The professor-facing story cannot be:

```text
manual fib-store / fib-funcinst / fib-moduleinst
  -> hand-assembled runtime config
  -> steps(...)
```

The intended story is:

```text
wasm / wat code
  -> Wasm module Maude term
  -> deterministic initial config generation
  -> generated C1 semantics
  -> steps / search / verification
```

The immediate C1 target is the middle of that pipeline:

```text
fib-module Maude term
  -> validation-preserving Module-ok / instantiate
  -> invoke
  -> unary steps(Config)
```

The benchmark harness may mention Fibonacci-specific names. The translator must
not.

## Important Files

- `translator_bs.ml`: C1 translator. Final fixes must be made here.
- `output_bs.maude`: generated C1 output. Do not patch manually as final.
- `wasm-exec-bs.maude`: benchmark harness for current Fibonacci evidence.
- `wasm-3.0/*.spectec`: source semantics.
- `translator.ml`, `output.maude`: older/C2 reference path; do not mix into C1.

Regenerate C1 output with:

```bash
dune exec ./main_bs.exe -- wasm-3.0/*.spectec > output_bs.maude
```

## Current Successful Evidence

The following are useful C1 regression tests.

`$expanddt` works:

```maude
red in WASM-FIB-BS :
  $expanddt(value('TYPE, fib-funcinst)) .
```

Expected/current result:

```maude
CTORFUNCARROWA2(CTORI32A0 CTORI32A0 CTORI32A0, CTORI32A0)
```

Generated `$invoke` works over the manually assembled store:

```maude
red in WASM-FIB-BS :
  $invoke(fib-store, 0, i32v(5) i32v(0) i32v(1)) .
```

Expected/current result: a concrete `Config`, not a stuck `$invoke(...)`.

Known invoke-path status:

```maude
rew [10000] in WASM-FIB-BS : steps(fib-config-invoke(i32v(5))) .
```

This path currently stops early at the known outer invoke frame/label/block term.
`$invoke(...)` itself still reduces to a concrete `Config`, but the full
`fib-config-invoke` execution should be treated as a separate invoke-path issue,
not as part of small cleanup tasks.

The older hand-assembled config path also remains a useful execution
regression:

```maude
rew [10000] in WASM-FIB-BS :
  steps(fib-config(i32v(5))) .
```

Expected/current final constant:

```maude
CTORCONSTA2(CTORI32A0, 5)
```

These tests prove that generated `step`, `step-pure`, `step-read`, `steps`, and
`$invoke` have meaningful execution coverage. They are not the final
professor-facing path, because `fib-store`, `fib-funcinst`, and
`fib-moduleinst` are still manually assembled by the harness.

## Current Blocker

The current C1 blocker is validation/typechecking execution:

```maude
red in WASM-FIB-BS :
  Module-ok(fib-module, CTORARROWA2(eps, eps)) .
```

This does not yet reduce to:

```maude
valid
```

Because this validation does not yet succeed, validation-preserving instantiate
is not complete:

```maude
rew [1] in WASM-FIB-BS :
  $instantiate(empty-store, fib-module, eps) .
```

The focus is currently:

```text
Module-ok
  -> Func-ok
  -> Expr-ok
  -> Instrs-ok
  -> Instr-ok / Instrtype-sub / Resulttype-sub / frame adaptation
```

Recent diagnosis narrowed the issue to generic SpecTec-to-Maude lowering
problems, not Fibonacci-specific semantics:

- nonempty `Instrs-ok` sequence validation can stack overflow or get stuck;
- same-input recursive adaptation rules must not be used as syntax-directed
  inference rules;
- SpecTec list-tail patterns such as `instr instr*` need correct singleton
  tail `eps` handling;
- output-bearing premises need mode-aware scheduling;
- partial-output inference must not force Maude to solve validation backwards;
- list elements that are themselves sequence-like need element-boundary
  preservation.

## Design Constraints

Do not add any of the following to C1:

- `mc`
- `exec-step`
- `focused-step`
- `dstep`
- C2-style execution adapters
- benchmark-specific rewrite rules
- output-level manual patches as final
- global `mb/cmb` to `$typed` conversion
- deletion of `OpTerminal`, `InstrTerminals`, or `ValTerminals`
- binary `steps`
- validation premise bypasses

Do not make execution pass by removing or weakening:

```maude
Module-ok(...)
Externaddr-ok(...)
Val-ok(...)
```

or other validation premises generated from SpecTec.

The following names must not appear as hardcoded strings in `translator_bs.ml`:

```text
fib
fib-module
fib-store
empty-store
CTORI32A0
Module-ok
Func-ok
Instrs-ok
Externaddr-ok
Val-ok
```

These names may appear in `output_bs.maude`, because that file is generated from
the Wasm SpecTec sources. They may also appear in `wasm-exec-bs.maude`, because
that file is a benchmark harness.

## Current Pruned Baseline

The recent helper-heavy Module-ok / init-config experiment has been pruned from
the active C1 baseline.

Current state:

- helper-heavy Module-ok/init-config changes are removed or deferred;
- `translator_bs.ml` is restored to the clean C1 baseline;
- `output_bs.maude` is regenerated from the translator;
- `dune build ./main_bs.exe` passes;
- `dune exec ./main_bs.exe -- wasm-3.0/*.spectec > output_bs.maude` passes;
- forbidden hardcoding grep on `translator_bs.ml` is empty:

```bash
grep -n "Func-ok\|Instrs-ok\|Module-ok\|Externaddr-ok\|fib\|CTORI32A0" translator_bs.ml
```

This means the current accepted C1 baseline supports execution smoke tests
through `fib-config` / `fib-config-invoke`, but source-module
validation-preserving initial config is still future work.

## Research Direction: C1 Baseline

### 1. Stop helper-heavy init-config path

Module-ok / init-config should not be forced to run by adding helper-heavy
shortcuts. That direction is not a C1-final candidate unless it can be justified
as generic, SpecTec-derived, validation-preserving infrastructure.

The following kinds of changes must stay removed or isolated as experimental:

- `$infer-*`, `$prove-*`, `$out-*`;
- `$record-update`, `$record-append`;
- `$seq-tail`, `$list-elem`;
- unsafe `$instantiate-eq`;
- unsafe `$init-invoke`;
- manual validation adapters that name Wasm judgements;
- Fibonacci-specific rules or copied instantiated stores/configs.

Past experiments should remain documented as experiments only. The active
baseline is the pruned C1 semantics that passes the accepted execution
regressions.

### 2. Make `output_bs.maude` more isomorphic

C1's core goal is to preserve SpecTec relation and rule structure as directly
as possible. The generated Maude should become cleaner before returning to
source-module initial config work.

#### 2.1 `step-from-step-pure-*`

Audit result: `step-from-step-pure-*` rules are derived `Step_pure`-to-`Step`
lifted shortcuts, not direct translations of original SpecTec `Step` rules.

Current cleanup state:

- non-label `step-from-step-pure-*` shortcuts are removed;
- only label-related `step-from-step-pure-*` shortcuts remain temporarily;
- the remaining label-related shortcuts are non-C1-final executable debt.

Reason for temporary retention: the strict single-rule translation of
`Step/ctxt-instrs` can match the intended associative split for terms such as
`label(... br 0) local.get 1`, and its individual conditions succeed, but Maude
does not combine that split with the conditional rewrite premise during full
rule application. Future work is to remove the remaining label-related
shortcuts by finding a faithful generic context-closure encoding or by moving
execution-control machinery to C2.

#### 2.2 Empty-result splits and `INSTRQ =/= eps` guards

Completed cleanup: the generated empty-result split rules have been removed, and
their companion `INSTRQ =/= eps` guards have been removed.

Removed rules:

- `step-ctxt-instrs-empty`;
- `step-pure-empty`;
- `step-read-empty`;
- `step-ctxt-label-empty`;
- `step-ctxt-handler-empty`.

The corresponding generated bridges/context rules now handle both `eps` and
non-`eps` inner results in a single rule. Keep regression tests for
label/br+suffix, br_if+suffix, nop+suffix, and `steps(fib-config(i32v(5)))`
after any further translator changes.

#### 2.3 Boolean condition cleanup

Professor feedback: conditions such as `(C =/= 0) = true` are often redundant
because Maude conditions may use Bool expressions directly. This should be
audited separately from the completed `INSTRQ =/= eps` cleanup.

Do not blindly delete every `= true`; first test representative generated
conditions such as arithmetic comparisons and `$is-*` predicates.

#### 2.4 Validation rules currently lowered as equations

Some validation rules such as `Module-ok`, `Func-ok`, and `Instrs-ok` are
currently generated as `eq/ceq ... = valid`.

The professor's requirement is that SpecTec `rule`s should be represented as
Maude `rl/crl` as much as possible. Therefore validation relation lowering must
be audited and likely redesigned.

Key research question:

```text
How can output-bearing validation premises preserve rule structure without
falling back to helper-heavy $infer/$prove/$out mode compilation?
```

#### 2.5 Generic SpecTec-to-Maude direction

C1 should be audited as a generic SpecTec-to-Maude translator, not only a Wasm
translator. Concrete tasks:

- grep `translator_bs.ml` for Wasm-specific hardcoding;
- consider renaming generic generated infrastructure from `WasmTerminal` /
  `WasmType` toward `SpecTecTerminal` / `SpecTecType`, or removing the broad
  type sort if the audit shows it is unnecessary;
- try `p4-spectec` or another non-Wasm SpecTec input as a smoke test;
- record unsupported SpecTec features as translator limitations rather than
  silently adding Wasm-specific hacks.

#### 2.6 `WasmType` / typecheck infrastructure audit

The current `WasmTerm`/`WasmType` framework may be legacy/ad-hoc. Audit it
before making invasive changes.

Clarifications:

- Do not delete Wasm object-language type syntax such as `i32`, `functype`,
  `heaptype`, or annotations that appear in source programs.
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
  runtime configurations? If so, can the syntax universe be reduced?
- Would a more elegant design use only necessary syntax categories and Maude
  sorts, rather than a broad type-tag framework?

### 3. Initial config path

After C1 isomorphism cleanup and rule-lowering policy are clarified, resume
source-module initial config work.

Target path:

```text
fib-module Maude term
  -> validation-preserving instantiate
  -> invoke
  -> unary steps(Config)
  -> Fibonacci result
```

The current manual/regression paths using `fib-store`, `fib-config`, and
`fib-config-invoke` are useful smoke tests, but they are not the final
source-module path. The final goal is that a source Wasm/WAT module term can
produce an initial config deterministically without user-written runtime config
shortcuts.

### 4. Wasm/WAT to Maude frontend

After `fib-module -> initial config -> steps` works, build frontend support:

```text
fib.wat or Wasm source
  -> translated/generated Maude module term
  -> run on generated output_bs.maude
```

The frontend is important, but it should come after the C1 semantics and
initial-config path are stable. Frontend support is separate from
`translator_bs.ml` and must not justify benchmark hardcoding in the translator.

### 5. Full cleanup and documentation

Clean and document:

- `translator_bs.ml`;
- `output_bs.maude` generation policy;
- `wasm-exec-bs.maude`;
- `README.md`;
- `STATUS.md`;
- `HowToTest.md`.

Also verify:

- all `wasm-3.0/*.spectec` inputs are translated as expected;
- no benchmark-specific hardcoding exists in `translator_bs.ml`;
- unnecessary generated helpers are removed or justified;
- warning categories are documented.

### 6. Mapping document for professor

Prepare examples showing how SpecTec constructs are translated:

- syntax declarations;
- defs/functions/equations;
- rules;
- `Step` / `Step_pure` / `Step_read` / `Steps`;
- representative direct rules and structural bridge rules.

Goal: ask the professor whether the translation is sufficiently
relation-preserving / isomorphic.

### 7. Warning cleanup

Classify Maude load warnings:

- advisory / cosmetic;
- multiple distinct parses;
- used-before-bound.

Prioritize used-before-bound warnings in validation relations:

- `Module-ok`;
- `Func-ok`;
- `Instrs-ok`;
- `Instr-ok`;
- `Externaddr-ok`;
- `Ref-ok`;
- subtype/type validation rules.

These warnings may be related to output-bearing premise scheduling and
initial-config blockers.

### 8. Model checking later

Model checking is deferred.

Only proceed to model checking after:

- C1 translation policy is stable;
- execution regressions pass;
- initial config path is clarified;
- generated semantics is cleaned up.

## Next Concrete Task

Do not jump to frontend, model checking, or broad speculative infrastructure.

First, finish the validation rule-lowering design audit and the generic/type
infrastructure audits. Then return to the current source-module blocker:

```maude
red in WASM-FIB-BS :
  Module-ok(fib-module, CTORARROWA2(eps, eps)) .
```

This term does not yet reduce to `valid`. When work resumes, debug one smallest
failing validation term at a time:

1. If it gets stuck in `Instrs-ok`, isolate the exact instruction sequence.
2. If it is a list-tail issue, fix generic SpecTec list-tail lowering.
3. If it is an output-bearing premise issue, fix generic rule-preserving
   scheduling.
4. Do not add translator rules that mention `Instrs-ok`, `Func-ok`,
   `Module-ok`, `fib`, or `CTORI32A0` by name.

Useful acceptance ladder after each translator change:

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

Final C1 professor-facing acceptance target:

```maude
rew [10000] in WASM-FIB-BS :
  steps(fib-config-instantiated(i32v(5))) .
```

Expected final result:

```maude
... ; CTORCONSTA2(CTORI32A0, 5)
```

Do not claim this final path is complete until the command above succeeds
without validation bypasses.

## Cleanup Guidance

Do not rely on stale `handoff/*.maude` harness files. If running from inside
`handoff`, use:

```maude
load ../wasm-exec-bs
```

instead of:

```maude
load wasm-exec-bs
```

Keep useful logs only if they still match the current generated output.
