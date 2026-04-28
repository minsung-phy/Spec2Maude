# Spec2Maude Status

Updated: 2026-04-28

This document is the current project state and execution plan. Historical debugging details are in `meeting/session_summary.txt` and `meeting/personal_meeting_0428/`.

---

## 1. Current Thesis Direction

The project goal is:

> Translate the WebAssembly 3.0 SpecTec semantics into Maude as faithfully as possible, then apply semantics-preserving transformations so that Maude rewriting and LTL model checking become practical.

The research pipeline is now clear:

1. **C1. Isomorphic baseline translation**
   - Implemented in `translator_bs.ml`.
   - Preserve SpecTec relations and rule structure in Maude.
   - Must be executable enough for small rewriting and small model checking.

2. **C2. Analysis-friendly transformation**
   - Implemented in `translator.ml` or a later optimized path.
   - Uses heat/cool, redex localization, abstraction, or other Maude-friendly transformations.
   - Must be checked against the baseline.

3. **C3. Model-checking evaluation**
   - Use Maude LTL model checker on Wasm programs.
   - Need benchmark/property tables, not only Fibonacci.

4. **C4. State-explosion handling**
   - Explain and reduce the state explosion that appears during model checking.
   - This is necessary for a PLDI-level story.

Important correction:

- `translator_bs.ml` is not allowed to be a dead reference artifact. It should support at least small model checking.
- `translator.ml` is the scalable model-checking path.
- The paper story is strongest when baseline and optimized semantics are both present and compared.

---

## 2. 2026-04-28 Professor Requirements

Meeting note source:

- `meeting/professor_requirement/0428_개인.txt`

### Requirement A: Preserve SpecTec relation names

SpecTec declares distinct relations:

```spectec
relation Step      : config ~> config
relation Step_pure : instr* ~> instr*
relation Step_read : config ~> instr*
relation Steps     : config ~>* config
```

The baseline should preserve these as distinct Maude rewrite operators.

Target shape:

```maude
op step      : Config -> Config .
op step-pure : WasmTerminals -> WasmTerminals .
op step-read : Config -> WasmTerminals .
op steps     : Config -> Config .
```

The exact Maude operator spelling can be adjusted if needed, but the four SpecTec relations must remain semantically separate.

### Requirement B: Do not encode `Steps` as `Judgement => valid`

Current generated baseline still has this non-isomorphic style:

```maude
Steps(CTORSEMICOLONA2(Z, IS), CTORSEMICOLONA2(Z2, IS2)) => valid
```

Professor wants the executable relation shape:

```maude
rl [steps-refl] :
  steps(Z ; IS) => Z ; IS .

crl [steps-trans] :
  steps(Z ; IS) => Z2 ; IS2
  if step(Z ; IS) => Z1 ; IS1
  /\ steps(Z1 ; IS1) => Z2 ; IS2 .
```

This is closer to the SpecTec `config ~>* config` relation.

### Requirement C: Use `_ ; _` instead of constructor noise

Current generated code exposes constructor names such as:

```maude
CTORSEMICOLONA2(Z, IS)
```

Target baseline should expose:

```maude
Z ; IS
```

Planned Maude declaration:

```maude
sort Config .
op _;_ : State WasmTerminals -> Config [ctor] .
```

This is not just cosmetic. It makes the generated Maude closer to the SpecTec surface rule:

```spectec
z; instr* ~> z'; instr'*
```

### Requirement D: Remove redundant membership guards

If Maude variables are already declared with precise sorts, do not add duplicate executable conditions like:

```maude
/\ Z : State
```

Reason:

```maude
var Z : State .
```

already restricts matching to `State`. In Maude, sorted variable matching performs the sort check.

Important nuance:

- Removing redundant guards is correct if variables are declared with the right sorts.
- This is different from blindly removing real semantic premises.
- `hasType(...) : WellTyped` should be kept only when it represents an actual SpecTec premise, not when it merely duplicates a variable sort annotation.

---

## 3. Current Implementation State

### Files

- `translator_bs.ml`
  - Baseline translator.
  - Current priority.
- `translator.ml`
  - Optimized/executable path.
  - Existing fib model checking has worked here.
- `main_bs.ml`
  - Baseline entry point.
- `main.ml`
  - Optimized entry point.
- `output_bs.maude`
  - Generated baseline output.
- `output.maude`
  - Generated optimized output.
- `wasm-exec-bs.maude`
  - Baseline harness.
- `wasm-exec.maude`
  - Optimized harness.

### Already Done

- Ubuntu build/run path repaired.
- Linux model-checker path set to:

```maude
load ../../tools/Maude-3.5.1-linux-x86_64/model-checker
```

- `translator_bs.ml` split from `translator.ml`.
- `main_bs.ml` added.
- Baseline can regenerate:

```sh
dune exec ./main_bs.exe -- wasm-3.0/* > output_bs.maude
```

- `focused-step` experiment was removed.
- `Step/ctxt-instrs` synthetic wrapper was removed.
- Professor's nil-split issue was confirmed and fixed for `Step/ctxt-instrs`.
  - Old recursive focus: `INSTR`
  - New recursive focus: `INSTR-HEAD : WasmTerminal` + `INSTR-REST : WasmTerminals`
  - This prevents empty recursive focus at the Maude LHS matching level.
- Baseline rewrite works for fib:

```maude
rew [10000] in WASM-FIB-BS : steps(fib-config(i32v(5))) .
```

Result:

- 24,902 rewrites
- final value `CTORCONSTA2(CTORI32A0, 5)`

- Timing script exists:

```sh
scripts/time_baseline_modelcheck.sh
```

### Not Done Yet

- Baseline v2 is not yet updated to the 2026-04-28 relation-preserving design.
- Current `output_bs.maude` still has:
  - `op step : ExecConf -> ExecConf`
  - `Steps(...) => valid`
  - `CTORSEMICOLONA2(...)`
- Baseline model checking is still too slow.
  - `fib(5)` reachability ran for more than 2 hours without result.
  - Earlier `fib(2)` reachability did not finish within 60 seconds.
- Full Wasm 3.0 `-- Step:` rule catalog is incomplete.
- `IterPr` / `IterE` lowering is not semantically complete.
- Bind-before-use warnings remain in GC/reference-related rules.
- There are no serious benchmarks beyond fib.
- There is no baseline-vs-optimized differential harness yet.

---

## 4. Immediate Engineering Plan

### P0. Rewrite baseline relation encoding

Owner file:

- `translator_bs.ml`

Goal:

- Make generated `output_bs.maude` match the four SpecTec execution relations.

Implement:

```maude
sort Config .
op _;_       : State WasmTerminals -> Config [ctor] .
op step      : Config -> Config .
op step-pure : WasmTerminals -> WasmTerminals .
op step-read : Config -> WasmTerminals .
op steps     : Config -> Config .
```

Translate relation conclusions:

| SpecTec relation | Target Maude shape |
|---|---|
| `Step: config ~> config` | `step(C) => C'` |
| `Step_pure: instr* ~> instr*` | `step-pure(IS) => IS'` |
| `Step_read: config ~> instr*` | `step-read(C) => IS'` |
| `Steps: config ~>* config` | `steps(C) => C'` |

Translate premises:

| SpecTec premise | Target Maude condition |
|---|---|
| `-- Step: C ~> C'` | `step(C) => C'` |
| `-- Step_pure: IS ~> IS'` | `step-pure(IS) => IS'` |
| `-- Step_read: C ~> IS'` | `step-read(C) => IS'` |
| `-- Steps: C ~>* C'` | `steps(C) => C'` |

Expected core generated rules:

```maude
crl [step-pure] :
  step(Z ; IS) => Z ; IS'
  if step-pure(IS) => IS' .

crl [step-read] :
  step(Z ; IS) => Z ; IS'
  if step-read(Z ; IS) => IS' .

rl [steps-refl] :
  steps(Z ; IS) => Z ; IS .

crl [steps-trans] :
  steps(Z ; IS) => Z2 ; IS2
  if step(Z ; IS) => Z1 ; IS1
  /\ steps(Z1 ; IS1) => Z2 ; IS2 .
```

Keep the nil-split fix:

```maude
crl [step-ctxt-instrs] :
  step(Z ; VAL W REST INSTR1)
  =>
  ZQ ; VAL INSTRQ INSTR1
  if all-vals(VAL) = true
  /\ ((VAL =/= eps) or (INSTR1 =/= eps)) = true
  /\ step(Z ; W REST) => ZQ ; INSTRQ .
```

### P1. Clean type/membership guards

Goal:

- Remove duplicate sort guards only when the variable declaration already enforces the sort.

Examples:

- Remove: `Z : State` if `var Z : State .`
- Keep: real semantic predicates such as `all-vals(VAL) = true`
- Keep or audit: `hasType(...) : WellTyped` depending on whether it is a real SpecTec premise or just a duplicated binder annotation.

Do not reintroduce raw `Z : State` as an executable condition to fix strictness. If strictness is needed, fix variable sorts and membership generation.

### P2. Verify baseline v2

After regenerating `output_bs.maude`, check these fragments manually:

- `step-pure`
- `step-read`
- `steps-refl`
- `steps-trans`
- `step-ctxt-instrs`
- `step-ctxt-label`
- `step-ctxt-handler`
- `step-ctxt-frame`

Required commands:

```sh
dune build
dune exec ./main_bs.exe -- wasm-3.0/* > output_bs.maude
maude -no-banner output_bs.maude
```

Baseline rewrite tests:

```maude
rew [1] in WASM-FIB-BS : step(fib-config(i32v(1))) .
rew [10000] in WASM-FIB-BS : steps(fib-config(i32v(0))) .
rew [10000] in WASM-FIB-BS : steps(fib-config(i32v(1))) .
rew [10000] in WASM-FIB-BS : steps(fib-config(i32v(2))) .
```

Baseline model-check timing:

```sh
scripts/time_baseline_modelcheck.sh 0 reach 60
scripts/time_baseline_modelcheck.sh 1 reach 300
scripts/time_baseline_modelcheck.sh 2 reach 600
```

Success criterion:

- Baseline must model-check at least very small cases.
- If not, diagnose the transition relation before optimizing.

### P3. Build optimized model-checking path

Owner file:

- `translator.ml`

Goal:

- Preserve the same semantics but make model checking practical.

Allowed transformations:

- heat/cool
- redex localization
- equation abstraction
- state-space reduction
- careful use of equations where semantics-preserving

Required evidence:

- Compare optimized results with baseline on small programs.
- Record runtime/state-space improvement.

---

## 5. What To Tell Professor Next

Short version:

> 0428 미팅 기준으로 baseline을 다시 정리하겠습니다. 기존 baseline은 `Step`, `Step_pure`, `Step_read`, `Steps`를 하나의 `step` 중심 구조로 섞어 사용했고, `Steps`도 `Judgement => valid`처럼 번역되어 isomorphic하지 않았습니다. 이제 `step`, `step-pure`, `step-read`, `steps`를 각각 Maude rewrite operator로 만들고, config도 `CTORSEMICOLONA2` 대신 `_ ; _`로 출력하도록 고치겠습니다. 또한 `var Z : State`처럼 sort가 이미 선언된 경우 `Z : State` condition은 제거하겠습니다.

Important clarification:

> `translator_bs.ml`도 작은 모델체킹은 돌아야 한다고 보고 있습니다. baseline은 faithful semantics이고, `translator.ml`은 그 위에 analysis-friendly transformation을 적용해 더 큰 benchmark를 돌리는 경로로 정리하겠습니다.

---

## 6. Paper Plan Summary

For the detailed paper plan, see `paper_plan.md`.

Minimum viable strong paper:

1. Relation-preserving SpecTec-to-Maude translator.
2. Baseline executable enough for small model checking.
3. Optimized semantics that scales beyond baseline.
4. Benchmarks and LTL properties beyond fib.
5. State-explosion analysis and reduction.

PLDI-level paper likely needs at least one extra research win:

- Wasm 3.0 spec ambiguity or bug.
- Production engine differential-testing finding.
- General state-space reduction method for SpecTec-generated rewriting semantics.
- A compelling set of new LTL properties for Wasm 3.0 features that existing tools cannot check directly.
