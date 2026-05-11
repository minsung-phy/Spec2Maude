# Spec2Maude Paper Plan

Updated: 2026-04-30

Engineering status is in `STATUS.md`.

---

## 1. Paper Thesis

One-sentence story:

> Spec2Maude translates WebAssembly 3.0 SpecTec semantics to Maude while
> preserving the original relation structure, then applies justified
> transformations that make the generated semantics usable for LTL model
> checking.

Core claim:

- A faithful relation-preserving translation is important as a reference.
- Directly model checking that faithful semantics causes severe state-space
  explosion.
- The research contribution is to separate:
  1. the faithful C1 baseline,
  2. the optimized C2 model-checking semantics,
  3. the evaluation showing why C2 is needed and how much it helps.

---

## 2. Contribution Plan

### C1. Relation-Preserving Baseline

Implementation:

- `translator_bs.ml`

Required shape:

- Preserve `Step`, `Step_pure`, `Step_read`, and `Steps`.
- Preserve rule names and premises.
- Use `_ ; _` for configs.
- Generate `steps(C) => C'`.
- Preserve `val^n` and `val*` structure.
- Avoid redundant executable sort guards when Maude declarations already enforce
  the sort.

Current status:

- Implemented.
- `step(fib-config(...))` performs generated C1 one-step execution.
- `steps(fib(0))` and `steps(fib(5))` can reach terminal configurations by
  Maude `search`.
- Direct initial-state model checking through `step(C) => C'` still times out
  even for `fib(0)`.
- No deterministic `dstep` driver is part of C1.

Interpretation:

- C1 is now useful as a relation-preserving executable reference.
- C1 is not yet practical as a direct model-checking target when the model
  checker must solve the full generated `step(C) => C'` relation.
- The honest C1 claim is: faithful translation and `Step`/`Steps` relation
  execution work; direct model checking still explodes.

### C2. Analysis-Friendly Transformation

Implementation:

- `translator.ml`

Purpose:

- Derive a model-checking-friendly semantics from C1.
- Reduce context/proof-search nondeterminism without changing observable Wasm
  behavior.

Likely techniques:

- heat/cool or focused evaluation contexts
- deterministic one-redex stepping
- context split pruning
- canonicalization of equivalent control-context states
- abstraction when the property permits it

Required evidence:

- C2 agrees with C1 on small rewrite tests.
- C2 model checking finishes where C1 times out.
- Any transformation is explained as a semantics-preserving optimization, not a
  hand-written replacement.
- Do not put benchmark-specific deterministic drivers into the C1 baseline.

### C3. Model-Checking Evaluation

Properties:

- Reachability: `<> result-is(N)`
- Safety: `[] ~ trap-seen`
- Progress/stuckness when expressible
- Feature-specific properties for memory/table/exception/GC rules

Benchmarks:

- fib
- factorial
- iterative sum/product
- memory load/store
- table/call-indirect
- exceptions
- GC struct/array operations

Tables needed:

- rewrite time for C1 and C2
- model-check time for C1 and C2
- number of rewrites/states when available
- timeout table

### C4. State-Explosion Analysis

Current evidence:

- C1 `step(fib(0))` one-step: 34 rewrites, immediate.
- C1 `search [1] steps(fib(0)) =>* Z ; i32v(0)`: found in 612 rewrites, about
  2ms Maude real time.
- C1 `search [1] steps(fib(5)) =>* Z ; i32v(5)`: found in 22,662 rewrites,
  about 48ms Maude real time.
- Direct C1 model checking with `exec-step if step(C) => C'`: timeout after 120
  seconds even for `fib(0)`.
- Reachability search from `mc(fib-config(i32v(0)))` times out quickly and shows
  nested label/control-context states.

Research angle:

- Faithful generated semantics is executable, but its context rules expose too
  much nondeterministic proof search to the model checker.
- C2 should be presented as a systematic reduction from the faithful semantics.
- The immediate professor-facing message should be that C1 is faithful and
  executable by rewriting, but not yet usable as a direct model-checking target.

---

## 3. PLDI Bar

C1 alone is not enough.

Minimum credible story:

```text
C1 faithful translation
+ C2 transformed executable semantics
+ C3 benchmark/property evaluation
+ C4 state-explosion diagnosis and reduction
```

PLDI likely needs one stronger research win:

1. A Wasm 3.0 spec ambiguity or bug.
2. A mismatch found by differential testing against V8/wasmtime/SpiderMonkey.
3. A general state-space reduction method for SpecTec-generated Maude semantics.
4. LTL verification of Wasm 3.0 features that existing tools cannot practically
   check.

---

## 4. Roadmap

### Phase 0: Finish C1 Baseline

Done:

- [x] Generate `_ ; _`.
- [x] Generate `step`, `step-pure`, `step-read`, `steps`.
- [x] Generate `steps(C) => C'`.
- [x] Preserve `val^n` length constraints.
- [x] Restrict `val*` binders with `ValTerminals`.
- [x] Prevent empty recursive focus in `Step/ctxt-instrs`.
- [x] Verify generated `step(...)` one-step execution.
- [x] Verify `steps(...)` reaches Fibonacci terminal states by `search`.
- [x] Fix model-check harness over-approximation with `mc(Config)`.

Still open:

- [ ] Ask professor whether the paper split is acceptable: C1 as faithful
      executable reference, C2 as optimized model-checking semantics.
- [ ] If professor requires direct C1 model checking, investigate a deeper Maude
      strategy/fairness/control mechanism for the strict rules.
- [ ] Explain clearly that no `dstep`/benchmark-specific driver is being used
      as evidence for C1.

### Phase 1: Build C2

Tasks:

- [ ] Rebuild `translator.ml` as a justified transformation from C1.
- [ ] Decide the C2 transformation only after professor feedback on the C1
      model-checking failure.
- [ ] Preserve observable agreement with C1 on small programs.
- [ ] Measure model-checking improvement on fib first.

### Phase 2: Broaden Coverage

Tasks:

- [ ] Complete Wasm 3.0 execution-rule coverage table.
- [ ] Classify unsupported patterns.
- [ ] Resolve major bind-before-use warnings.
- [ ] Add non-fib benchmarks.

### Phase 3: Evaluation

Tasks:

- [ ] 5+ benchmarks.
- [ ] 3+ properties per benchmark.
- [ ] C1-vs-C2 rewrite table.
- [ ] C1-vs-C2 model-check table.
- [ ] Timeout/state-explosion table.

### Phase 4: Research Win

Tasks:

- [ ] Differential testing harness.
- [ ] Wasm 3.0 feature case study.
- [ ] Search for spec ambiguity or engine mismatch.
- [ ] Generalize the state-space reduction technique.

---

## 5. Writing Guidance

Do not claim:

- "The faithful baseline scales to model checking."

Honest claim:

- "The faithful baseline preserves the SpecTec relations and reaches small
  terminal configurations through `Step`/`Steps` search."
- "Direct model checking over the faithful baseline exposes severe state-space
  explosion."
- "The optimized translation is necessary for practical model checking."

Next figure/table:

- A table with C1 `step(...)` and `steps(...)` search results.
- A table showing direct C1 model-check timeout from initial `fib(0)`.
- A short diagram:

```text
SpecTec -> C1 relation-preserving Maude -> C2 optimized Maude -> model checking
```
