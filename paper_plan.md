# Spec2Maude Paper Plan

Updated: 2026-04-28

This document is the research and paper plan. Engineering status is in `STATUS.md`.

---

## 1. Target

Primary long-term target:

- **PLDI-level paper**, if the project obtains a strong research win beyond engineering.

Realistic strong targets:

- CAV
- OOPSLA
- TACAS
- ESOP
- FM
- VMCAI

Current judgement:

- C1+C2+C3 can make a strong formal-methods paper.
- PLDI likely requires C4 plus at least one concrete finding or broadly useful technique.

---

## 2. Core Paper Thesis

One-sentence paper story:

> We present Spec2Maude, a relation-preserving translation from the WebAssembly 3.0 SpecTec semantics to Maude, and show how semantics-preserving transformations make the generated rewriting semantics usable for LTL model checking.

Longer story:

1. SpecTec is the official-style semantic metalanguage for Wasm 3.0.
2. Existing executable semantics are often hand-curated.
3. We automatically translate SpecTec into Maude.
4. A direct isomorphic translation is faithful but can be hostile to model checking.
5. We therefore separate:
   - faithful baseline translation
   - analysis-friendly transformation
6. We evaluate the result with Maude rewriting and LTL model checking.
7. We study state explosion and show reductions/transformations that make verification practical.

---

## 3. Contribution Structure

### C1. Isomorphic SpecTec-to-Maude Translation

Implementation:

- `translator_bs.ml`

Required claims:

- Preserves SpecTec relation structure.
- Preserves rule names and premises.
- Uses Maude rewrite rules for SpecTec rewrite relations.
- Avoids hiding SpecTec semantics behind hand-written execution rules.

Current professor requirement:

- Preserve these four relations distinctly:

```spectec
Step      : config ~> config
Step_pure : instr* ~> instr*
Step_read : config ~> instr*
Steps     : config ~>* config
```

Target generated Maude shape:

```maude
step(C)      => C'
step-pure(I) => I'
step-read(C) => I'
steps(C)     => C'
```

Minimum acceptance criterion:

- Generated baseline loads.
- Small rewrite tests pass.
- Small model-checking tests pass.

Why this matters:

- This is the foundation that lets reviewers trust later optimizations.
- Without C1, the project looks like another hand-written Wasm semantics.

### C2. Semantics-Preserving Analysis-Friendly Transformation

Implementation:

- `translator.ml`

Purpose:

- Make Maude rewriting/model checking practical.
- Keep the transformation justified by comparison with C1.

Possible transformations:

- heat/cool
- redex localization
- equation abstraction
- state-space reduction
- sorting/subsorting improvements
- memoization or canonicalization where Maude supports it

Required evidence:

- Baseline and optimized semantics agree on small programs.
- Optimized path handles larger benchmarks or properties that baseline cannot.

Why this matters:

- This is the bridge from “faithful translation” to “usable verification tool.”

### C3. Maude LTL Model Checking of Wasm Programs

Implementation:

- Maude harnesses and benchmark suite.

Properties:

- reachability: `<> result-is(N)`
- safety: `[] ~ trap-seen`
- progress/stuckness: `[] ~ stuck`
- feature-specific properties:
  - exception handler matching
  - branch/label control preservation
  - GC null/reference behavior
  - memory/table bounds behavior

Required benchmark growth:

- fib
- factorial
- iterative sum/product
- memory load/store
- table/call-indirect
- exception try/catch/throw
- GC struct/array get/set

Why this matters:

- C3 is the visible verification result.
- It differentiates the work from translations that only execute programs.

### C4. State Explosion Analysis and Reduction

Problem:

- Model checking over generated rewriting semantics causes state explosion.
- This already appears in the direct baseline: `fib(5)` modelCheck can run for hours.

Paper contribution:

- Identify where explosion comes from:
  - overlapping conditional rules
  - associative sequence matching
  - context decomposition choices
  - unhelpful equations/rules in transition relation
- Show transformations that reduce it:
  - redex-localized stepping
  - heat/cool discipline
  - abstraction equations
  - canonical configurations
  - pruning impossible context splits

Why this matters:

- This can become the PLDI-level technical contribution if generalized beyond one benchmark.

---

## 4. PLDI Bar

C1 alone is not enough for PLDI.

C1+C2+C3 may be enough for a strong formal-methods venue if implemented well.

For PLDI, aim for:

```text
C1 faithful automatic translation
+ C2 semantics-preserving transformation framework
+ C3 meaningful model-checking evaluation
+ C4 state-explosion reduction technique
+ one research win
```

Research win options:

1. Find a Wasm 3.0 spec ambiguity or bug.
2. Find a differential-testing mismatch with V8, wasmtime, SpiderMonkey, or the reference interpreter.
3. Develop a generally applicable state-space reduction method for SpecTec-generated Maude semantics.
4. Demonstrate LTL properties for Wasm 3.0 features that existing Wasm semantics tools cannot practically check.

Current most realistic PLDI path:

- C1 baseline translator
- C2 optimized transformation
- C3 benchmark/property suite
- C4 state-explosion reduction
- plus either differential testing or a strong Wasm 3.0 feature case study

---

## 5. Development Roadmap

### Phase 0: Baseline v2, 2026-04 to 2026-05

Goal:

- Implement professor's 2026-04-28 relation-preserving baseline.

Tasks:

- [ ] Generate `Config` and `_ ; _`.
- [ ] Generate distinct `step`, `step-pure`, `step-read`, `steps`.
- [ ] Translate `Steps` as `steps(C) => C'`, not `Judgement => valid`.
- [ ] Remove redundant sort guards when variables are already sorted.
- [ ] Preserve nil-split fix for `Step/ctxt-instrs`.
- [ ] Regenerate `output_bs.maude`.
- [ ] Verify core rule shapes.
- [ ] Run small rewrite tests.
- [ ] Run small model-checking tests.

Exit criterion:

- `fib(0)` and `fib(1)` modelCheck finish on baseline.
- If `fib(2)` does not finish, record why and use it as state-explosion evidence.

### Phase 1: Baseline Coverage, 2026-05 to 2026-06

Goal:

- Know exactly what is translated and what is not.

Tasks:

- [ ] Complete full Wasm 3.0 `-- Step:` rule catalog.
- [ ] Classify rule patterns:
  - pure
  - read
  - state-changing
  - context
  - iterated premise
  - static premise
- [ ] Fix or explicitly reject unsupported patterns.
- [ ] Resolve major bind-before-use warnings.

Exit criterion:

- Coverage table.
- Unsupported rule list with reasons.

### Phase 2: Optimized Semantics, 2026-06 to 2026-08

Goal:

- Make model checking practical.

Tasks:

- [ ] Rebuild `translator.ml` as a justified transformation from baseline.
- [ ] Implement heat/cool or redex-localized stepping.
- [ ] Compare optimized vs baseline on small benchmarks.
- [ ] Record speed/state-space improvements.

Exit criterion:

- Optimized path model-checks beyond what baseline can handle.

### Phase 3: Benchmark and Property Suite, 2026-08 to 2026-10

Goal:

- Produce evaluation tables.

Tasks:

- [ ] Add 5+ benchmarks.
- [ ] Add 3+ properties per benchmark.
- [ ] Measure rewrite time.
- [ ] Measure model-checking time.
- [ ] Compare baseline vs optimized.

Exit criterion:

- Evaluation table suitable for paper draft.

### Phase 4: Research Win, 2026-10 to 2027-02

Goal:

- Move from engineering paper to top-tier paper.

Tasks:

- [ ] Differential testing harness.
- [ ] Wasm 3.0 feature case studies.
- [ ] Search for spec ambiguity / engine mismatch.
- [ ] Generalize state-space reduction technique.

Exit criterion:

- At least one result that is not just “we built a translator.”

### Phase 5: Writing, 2027

Tasks:

- [ ] Introduction and motivation.
- [ ] SpecTec-to-Maude translation rules.
- [ ] Correctness/faithfulness argument.
- [ ] Transformation framework.
- [ ] Model-checking methodology.
- [ ] Evaluation.
- [ ] Related work:
  - K-Wasm
  - Wasm reference interpreter
  - Ott/Lem
  - PLT Redex
  - Maude model checking
- [ ] Artifact instructions.

---

## 6. Immediate Next Paper Tasks

Do these now:

1. Fix baseline v2 according to the 2026-04-28 professor requirements.
2. Make baseline small modelCheck work or produce a precise state-explosion diagnosis.
3. Write a short baseline design note:
   - SpecTec rule
   - generated Maude rule
   - why it is isomorphic
4. Create first benchmark/property table using fib only.
5. Add one non-fib benchmark.

Do not do yet:

- Do not chase PLDI writing before C1 baseline is clean.
- Do not optimize before baseline v2 rule shapes are correct.
- Do not claim strict 1:1 if `Steps` is still `Judgement => valid`.
