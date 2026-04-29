# Spec2Maude Paper Plan

Updated: 2026-04-28

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
- `fib(0)`, `fib(1)`, `fib(5)` rewrite successfully.
- `steps(fib(5))` rewrites successfully.
- Initial-state model checking still times out even for `fib(0)`.

Interpretation:

- C1 is now useful as an executable reference for rewriting.
- C1 is not yet practical as a direct model-checking target.

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

- C1 `fib(5)` rewrite: 33,965 rewrites, about 44ms Maude real time.
- C1 `steps(fib(5))`: 33,966 rewrites, about 45ms Maude real time.
- C1 `modelCheck(mc(fib-config(i32v(0))), <> result-is(0))`: timeout after
  120 seconds.
- Reachability search from `mc(fib-config(i32v(0)))` times out quickly and shows
  nested label/control-context states.

Research angle:

- Faithful generated semantics is executable, but its context rules expose too
  much nondeterministic proof search to the model checker.
- C2 should be presented as a systematic reduction from the faithful semantics.

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
- [x] Verify `fib(0)`, `fib(1)`, `fib(5)` rewriting.
- [x] Verify `steps(fib(5))` rewriting.
- [x] Fix model-check harness over-approximation with `mc(Config)`.

Still open:

- [ ] Ask professor whether C1 must model-check from initial states, or whether
      C1 rewrite/reference execution is enough.
- [ ] If professor requires direct C1 model checking, investigate a deeper Maude
      strategy/fairness/control mechanism for the strict rules.

### Phase 1: Build C2

Tasks:

- [ ] Rebuild `translator.ml` as a justified transformation from C1.
- [ ] Add deterministic/focused stepping for model checking.
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

- "The faithful baseline executes small programs by rewriting and serves as the
  reference semantics."
- "Direct model checking over the faithful baseline exposes severe state-space
  explosion."
- "The optimized translation is necessary for practical model checking."

Next figure/table:

- A table with C1 `fib(0/1/5)` rewrite and `steps` results.
- A table showing C1 model-check timeout from initial `fib(0)`.
- A short diagram:

```text
SpecTec -> C1 relation-preserving Maude -> C2 optimized Maude -> model checking
```
