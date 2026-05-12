# Spec2Maude Paper Plan

Updated: 2026-05-12

Engineering status is in `STATUS.md`. This file is the research plan.

## Thesis

Spec2Maude translates WebAssembly 3.0 SpecTec semantics to Maude while
preserving the original relation structure, then derives a justified
analysis-friendly semantics for practical LTL model checking.

The paper needs three connected artifacts:

1. C1: faithful relation-preserving translation.
2. C2: semantics-preserving analysis transformation.
3. Evaluation: evidence that C2 agrees with C1 but model-checks better.

## Contributions

C1 baseline:

- Implemented in `translator_bs.ml`.
- Generated artifact is `output_bs.maude`.
- Must preserve `Step`, `Step_pure`, `Step_read`, and `Steps`.
- Must use unary `steps(C) => C'`.
- Must use `_ ; _` for configs.
- Must use WT/`WasmTerminal`, not RT/`RecordTerminal`.
- Must not use `dstep`, `focused-step`, `mc`, or benchmark-specific execution
  drivers as part of the baseline semantics.
- Must not hard-code benchmark-specific functions such as Fibonacci execution.

C2 transformation:

- Implemented later in `translator.ml`.
- May use heat/cool, focusing, context pruning, canonicalization, or other
  analysis-friendly transformations.
- Must be justified against C1 on small executions.
- Must be the path for practical model checking if direct C1 explodes.

Evaluation:

- Compare C1 and C2 on rewrite/search/model-checking time.
- Include timeout/state-space results.
- Cover more than Fibonacci before a PLDI submission.

## Current Research Status

Done:

- C1 generates distinct `step`, `step-pure`, `step-read`, and `steps`.
- C1 generates unary `steps`.
- Configs use `_ ; _`.
- Optional `eps` cases are generated generally.
- `Step/ctxt-instrs` avoids empty recursive focus.
- `mc` and deterministic `dstep` are not part of generated C1.
- The previously hand-written executable `$invoke` footer has been removed from
  `translator_bs.ml`; only the SpecTec-generated `$invoke` remains.
- Generic `(i<n)` type-iteration lowering for `rollrt`/`unrollrt`/`rolldt` was
  fixed, so the fib function type can now be expanded without the old
  `FREE-UNROLLRT0-I` style free iterator.

Not done:

- C1 Fibonacci execution is not yet complete.
- `fib-config(i32v(5))` reduces to a plausible call-ref config, and
  `$expanddt(fib-type)` now succeeds.
- The first `step-read` still overflows, but the current minimum reproducer is
  `red CTORLEA1(CTORSA0)`, which appears in the fib function body through
  `CTORRELOPA2(CTORI32A0, CTORLEA1(CTORSA0))`.
- Direct `steps(fib-config(...))` execution without `mc` is therefore not
  proven yet.
- C1 model checking has not reached the real state-explosion experiment yet.

## PLDI Bar

C1 alone is not enough for PLDI.

Minimum credible story:

```text
SpecTec
  -> C1 relation-preserving Maude
  -> C2 analysis-friendly Maude
  -> Maude LTL model checking
```

The paper should eventually provide at least one strong research win:

1. A general transformation that makes SpecTec-generated Maude semantics
   model-checkable.
2. LTL verification of WebAssembly 3.0 features that are hard for existing
   tools.
3. A spec ambiguity or bug found through the executable semantics.
4. A mismatch found by differential testing against real engines.

## Roadmap

Phase 0: finish C1 execution.

- [x] Generate the professor-requested relation names.
- [x] Generate unary `steps`.
- [x] Use `_ ; _`.
- [x] Keep WT/`WasmTerminal`.
- [x] Remove `dstep`/`focused-step` from C1.
- [x] Remove hard-coded executable `$invoke` from the translator.
- [x] Remove `mc` from the main baseline harness path.
- [x] Fix `$expanddt/$unrolldt` stack overflow for the generic fib type
      unrolling path.
- [ ] Fix signed numeric operator constructor/membership executability
      generically (`CTORLEA1(CTORSA0)` is the current minimum reproducer).
- [ ] Verify `step-pure`, `step-read`, `step`, and `steps` with Maude
      commands.
- [ ] Make Fibonacci run through `steps` without `mc`.
- [ ] Decide whether `$invoke` or `$instantiate` is the right final initial
      config path.

Phase 1: build C2.

- [ ] Rebuild `translator.ml` as a transformation from C1.
- [ ] Pick the first transformation that makes Fibonacci model checking finish.
- [ ] Check C1/C2 agreement on small executions.
- [ ] Measure C1 timeout vs C2 success.

Phase 2: broaden evaluation.

- [ ] Add factorial and iterative sum/product.
- [ ] Add memory/table examples.
- [ ] Add exception and GC examples if possible.
- [ ] Add repeatable timing scripts.
- [ ] Produce C1-vs-C2 result tables.

## Claims To Avoid

Do not claim:

- C1 model checking fails because of state explosion yet.
- `mc` is needed for the professor's baseline.
- `mc` is part of translated semantics.
- The current Fibonacci harness is final.
- `$invoke` is hand-coded in C1.

Current honest claim:

> C1 now has the professor-requested relation shape, but direct execution is
> still blocked before model checking. The earlier generated type-unrolling
> issue for `call_ref` is fixed; the current minimum blocker is reducing the
> signed numeric operator constructor `CTORLEA1(CTORSA0)`, which appears in the
> Fibonacci body. The next task is to fix that constructor/membership
> executability generally, then rerun direct `step`/`steps` evidence without
> `mc`.
