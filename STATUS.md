# Spec2Maude Status

Updated: 2026-04-28

This file is the current engineering checkpoint. Historical debugging details
are in `meeting/session_summary.txt` and `meeting/personal_meeting_0428/`.

---

## 1. Current Direction

Research goal:

> Translate WebAssembly 3.0 SpecTec semantics to Maude in a relation-preserving
> way, then apply justified transformations so Maude rewriting and LTL model
> checking become practical.

Pipeline:

1. **C1. Isomorphic baseline translation** (`translator_bs.ml`)
   - Preserve SpecTec relations, rule names, and premises.
   - Must execute enough small programs to serve as the reference semantics.
2. **C2. Analysis-friendly transformation** (`translator.ml`)
   - Derived from C1.
   - Can use heat/cool, redex localization, pruning, or canonicalization.
   - Must make model checking practical.
3. **C3. Evaluation**
   - Benchmarks and Maude LTL properties.
   - Compare C1 and C2.
4. **C4. State-explosion explanation**
   - Explain why faithful generated semantics is hard to model check.
   - Show which transformations reduce the state space.

---

## 2. Professor Requirements From 2026-04-28

Source:

- `meeting/professor_requirement/0428_개인.txt`

Required baseline relations:

```spectec
relation Step      : config ~> config
relation Step_pure : instr* ~> instr*
relation Step_read : config ~> instr*
relation Steps     : config ~>* config
```

Generated Maude shape:

```maude
op step      : Config -> StepConf .
op step-pure : WasmTerminals -> StepPureConf .
op step-read : Config -> StepReadConf .
op steps     : Config -> StepsConf .
```

Additional requirements:

- Use `Z ; IS` for configs instead of exposing `CTORSEMICOLONA2(Z, IS)`.
- Generate `steps(C) => C'`, not `Steps(C, C') => valid`.
- Do not emit redundant executable sort guards when the Maude variable
  declaration already enforces the sort.
- Follow the SpecTec relation structure first; optimization belongs in C2.

---

## 3. Implemented Now

Changed files:

- `lib/frontend/elab.ml`
- `translator_bs.ml`
- `output_bs.maude`
- `wasm-exec-bs.maude`

Implemented in C1:

- `Step`, `Step_pure`, `Step_read`, and `Steps` are distinct generated
  relations.
- `Step/pure` and `Step/read` call `step-pure(...)` and `step-read(...)`
  instead of collapsing everything into one `step(...)` relation.
- `Steps/trans` is generated as:

```maude
steps(C) => C''
  if step(C) => C' /\ steps(C') => C'' .
```

- Configs are printed with `_ ; _`.
- `val^n` binders are preserved through elaboration and translated to length
  constraints such as `len(VAL) == N`.
- `val*` binders are declared as `ValTerminals`, not arbitrary
  `WasmTerminals`.
  - This keeps a `val*` prefix from consuming non-value instructions.
  - It directly addresses the professor's nil/list-split concern.
- `Step/ctxt-instrs` is still emitted as a generic context rule, but its
  recursive focus is structurally non-empty:

```maude
VAL INSTR-HEAD INSTR-REST INSTR1
```

  instead of one unconstrained `INSTR` sequence variable.
- Empty and non-empty result cases are split when needed because Maude cannot
  bind a sequence result to `eps` through the same pattern reliably.

Implemented in model-check harness:

- `wasm-exec-bs.maude` now wraps model-check states as `mc(Config)`.
- `exec-step` rewrites only `MCConfig`, not raw `Config`.
- This prevents the harness rule from recursively participating while Maude
  solves the condition `step(C) => C'`.

Important current interpretation:

- The translator is now following the professor's C1 relation-preserving
  direction.
- The `mc(...)` wrapper is harness-level only; it is not a semantic rule copied
  from the senior code.
- C1 rewriting works, but C1 model checking still does not scale.

---

## 4. Verification Results

Build and regeneration:

```sh
dune build
dune exec ./main_bs.exe -- wasm-3.0/* > output_bs.maude
```

Both succeeded.

### Direct Stuck-Point Test

Test:

```maude
rew [10000] in WASM-FIB-BS :
  step(fib-state(i32v(0)) ;
    CTORLABELLBRACERBRACEA3(0, eps, CTORBRA1(0)) CTORLOCALGETA1(1)) .
```

Result:

- Succeeds.
- Final instruction ends with `CTORCONSTA2(CTORI32A0, 0)`.
- 156 rewrites.
- About 1ms Maude real time.

### Rewriting

| Command | Result | Rewrites | Maude time |
|---|---:|---:|---:|
| `rew [10000] ... fib-config(i32v(0))` | `i32v(0)` | 945 | 2ms real |
| `rew [10000] ... fib-config(i32v(1))` | `i32v(1)` | 7,549 | 10ms real |
| `rew [10000] ... fib-config(i32v(5))` | `i32v(5)` | 33,965 | 44ms real |
| `rew [10000] ... steps(fib-config(i32v(5)))` | `i32v(5)` | 33,966 | 45ms real |

Conclusion:

- C1 rewrite execution is no longer stack-overflowing.
- `steps(...)` also terminates quickly for `fib(5)`.

### Model Checking

Sanity checks on terminal states:

```maude
red in WASM-FIB-BS-PROPS :
  mc(fib-state(i32v(0)) ; CTORCONSTA2(CTORI32A0, 0)) |= result-is(0) .
```

Result:

- `true`
- 19 rewrites

```maude
red in WASM-FIB-BS-PROPS :
  modelCheck(mc(fib-state(i32v(0)) ; CTORCONSTA2(CTORI32A0, 0)), <> result-is(0)) .
```

Result:

- `true`
- 25 rewrites

Initial-state model checking:

```maude
red in WASM-FIB-BS-PROPS :
  modelCheck(mc(fib-config(i32v(0))), <> result-is(0)) .
```

Result:

- Timed out after 120 seconds.
- No result was produced.

Reachability diagnostic:

```maude
search [50] in WASM-FIB-BS-PROPS :
  mc(fib-config(i32v(0))) =>* S:MCConfig .
```

Result:

- Timed out after 20 seconds.
- Only the first few states were printed before timeout.
- The reached states already include nested label/control contexts.

Current conclusion:

- The previous harness over-approximation problem is fixed by `mc(...)`.
- The remaining model-checking failure is C1 state-space/proof-search explosion.
- This is no longer just stack overflow; it is the cost of model checking the
  faithful context semantics directly.

---

## 5. What To Do Next

### P0. Report C1 Result To Professor

Accurate message:

> 교수님 말씀대로 C1을 `Step`, `Step_pure`, `Step_read`, `Steps` relation을
> 보존하는 형태로 수정했습니다. `val*`는 `ValTerminals`로 제한했고,
> `Step/ctxt-instrs`의 recursive focus는 non-empty가 되도록 해서 교수님이
> 말씀하신 nil split 문제를 막았습니다. 그 결과 `fib(0)`, `fib(1)`,
> `fib(5)` rewrite와 `steps(fib(5))`는 빠르게 성공합니다. 다만 `mc(...)`
> wrapper로 model-check harness의 과대전이까지 막은 뒤에도
> `modelCheck(mc(fib-config(i32v(0))), <> result-is(0))`가 120초 timeout입니다.
> 현재 남은 문제는 direct C1 semantics 자체의 state-space explosion으로
> 보입니다. 그래서 C1은 reference semantics로 유지하고, 실제 model checking은
> C2 transformation에서 줄여야 합니다.

### P1. Confirm C1 Exit Criterion

Need professor decision:

- Is C1 required to model-check even `fib(0)` from the initial state?
- Or is C1 allowed to be the faithful executable reference, with model checking
  scalability handled by C2?

This matters because the current strict C1 rewrite works but model checking does
not finish.

### P2. Start C2 From The Current C1

Likely C2 work:

- Deterministic one-redex projection for model checking.
- Heat/cool or focused evaluation contexts.
- Context split pruning.
- Canonicalization of semantically equivalent control contexts.

Required evidence:

- C2 agrees with C1 on small rewrite results.
- C2 model checking finishes where C1 times out.

### P3. Add Benchmark Coverage

After the C2 transition relation works:

- factorial
- iterative sum/product
- memory load/store
- table/call-indirect
- exception try/catch/throw

---

## 6. Commands

Build:

```sh
dune build
```

Generate C1 baseline:

```sh
dune exec ./main_bs.exe -- wasm-3.0/* > output_bs.maude
```

Run Maude:

```sh
maude wasm-exec-bs.maude
```

Useful tests:

```maude
rew [10000] in WASM-FIB-BS : fib-config(i32v(0)) .
rew [10000] in WASM-FIB-BS : fib-config(i32v(1)) .
rew [10000] in WASM-FIB-BS : fib-config(i32v(5)) .
rew [10000] in WASM-FIB-BS : steps(fib-config(i32v(5))) .
red in WASM-FIB-BS-PROPS : modelCheck(mc(fib-config(i32v(0))), <> result-is(0)) .
```
