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

## Professor Requirement

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

The invoke-based manual-store execution path works:

```maude
rew [10000] in WASM-FIB-BS : steps(fib-config-invoke(i32v(0))) .
rew [10000] in WASM-FIB-BS : steps(fib-config-invoke(i32v(1))) .
rew [10000] in WASM-FIB-BS : steps(fib-config-invoke(i32v(5))) .
```

Expected/current final constants:

```maude
CTORCONSTA2(CTORI32A0, 0)
CTORCONSTA2(CTORI32A0, 1)
CTORCONSTA2(CTORI32A0, 5)
```

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

Generated output contains derived lifted rules such as:

```maude
crl [step-from-step-pure-br-if-true] :
  step((Z ; CONST(I32, C) BRIF(L)))
  =>
  (Z ; BR(L))
  if ((C =/= 0)) = true /\ $is-labelidx(L) = true .
```

Manual ablation showed at least `step-from-step-pure-br-if-true` is redundant
for current regressions.

Do not delete all `step-from-step-pure-*` rules blindly. Audit them by rule
group and remove generation only when generic bridge/context rules already
cover the behavior.

#### 2.2 `INSTRQ =/= eps` guards

Do not globally delete all `INSTRQ =/= eps` guards. Some may be executable
case-splitting guards.

Current strong manual evidence supports removing the guard specifically from
`step-ctxt-instrs`. `step-pure` / `step-read` bridge guards require separate
tests before removal.

#### 2.3 `step-ctxt-instrs-empty`

Manual ablation showed strong evidence that the generated output can be closer
to the original SpecTec `Step/ctxt-instrs` rule by:

- removing `crl [step-ctxt-instrs-empty]`;
- removing `(INSTRQ =/= eps) = true` only from `step-ctxt-instrs`;
- using the single `step-ctxt-instrs` rule for both empty and non-empty inner
  results.

Focused label/br+suffix, br_if+suffix, nop+suffix, and Fibonacci `steps` tests
passed under that manual ablation. This is a high-priority isomorphism cleanup
candidate, but it still needs a generic translator-side implementation and
regression confirmation.

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

First, clean up C1 isomorphism and rule-lowering policy. Then return to the
current source-module blocker:

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
