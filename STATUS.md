# Spec2Maude Status

Updated: 2026-04-30

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

- `translator_bs.ml`
- `output_bs.maude`
- `wasm-exec-bs.maude`

Do not edit `lib/frontend/elab.ml` for the current C1 work. The active
baseline changes are in the translator and Maude harness only.

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
- `output_bs.maude` keeps the professor-requested generated C1 relations:
  `step`, `step-pure`, `step-read`, and `steps`.
- `exec-step` now uses the generated C1 relation directly:

```maude
mc(C) => mc(C') if step(C) => C' .
```

- No `dstep`, RT, or RecordTerminal driver is active in the C1 baseline.
- This makes the current harness faithful to C1, but it also exposes the known
  model-checking explosion.

Important current interpretation:

- The translator is now following the professor's C1 relation-preserving
  direction.
- The `mc(...)` wrapper is only the Maude model-checking state wrapper; it is
  not a semantic shortcut.
- Strict generated C1 relation execution works through `step(...)`/`steps(...)`.
- Strict generated C1 model checking from the initial Fibonacci state does not
  finish in the measured timeout.
- Current reporting stance: C1 is implemented faithfully, but direct C1 model
  checking is not practical yet.

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

### C1 Relation Execution

| Command | Result | Rewrites | Maude time |
|---|---:|---:|---:|
| `rew [1000] ... step(fib-config(i32v(0)))` | one C1 step into label config | 34 | 0ms real |
| `search [1] ... steps(fib-config(i32v(0))) =>* Z ; i32v(0)` | found | 612 | 2ms real |
| `search [1] ... steps(fib-config(i32v(5))) =>* Z ; i32v(5)` | found | 22,662 | 48ms real |

Conclusion:

- C1 relation execution is no longer stack-overflowing.
- Raw `rew fib-config(...)` is not the right C1 execution test because the
  generated execution relation is `step(Config)`, not a rewrite rule directly
  on `Config`.
- Raw `rew steps(fib-config(...))` can stop immediately by applying
  `steps-refl`; use `search` to demonstrate that `Steps/trans` reaches the
  terminal configuration.

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

Strict direct C1 model checking attempt:

```maude
red in WASM-FIB-BS-PROPS :
  modelCheck(mc(fib-config(i32v(0))), <> result-is(0)) .
```

Old result when `exec-step` used `step(C) => C'` directly:

- Timed out after 120 seconds.
- No result was produced.

Rechecked on 2026-04-30 after removing the temporary `dstep` experiment:

- Timed out after 20 seconds.
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
- Directly asking Maude to solve `step(C) => C'` for the generated C1 relation
  still causes state-space/proof-search explosion.
- We should not put a deterministic `dstep` driver in C1, because that would
  blur the distinction between faithful baseline and optimized analysis
  semantics.
- Current conclusion to report: C1 `step`/`steps` relation execution works, but
  direct C1 model checking does not finish.

---

## 5. What To Do Next

### P0. Report C1 Result To Professor

Accurate message:

> 교수님 말씀대로 C1은 `Step`, `Step_pure`, `Step_read`, `Steps` relation을
> 보존하는 형태로 유지했습니다. `val*`는 `ValTerminals`로 제한했고,
> `Step/ctxt-instrs`의 recursive focus는 non-empty가 되도록 해서 nil split을
> 막았습니다. `step(fib-config(...))` one-step은 동작하고, `steps(...)`
> relation으로 terminal config에 도달하는 것은 `search`로 확인했습니다.
> 다만 model checker가 `step(C) => C'`를 직접 풀게 하면 generic context
> split을 전부 탐색해서 폭발합니다. 그래서 direct C1 model checking은
> `fib(0)`에서도 timeout이 납니다. 현재 기준으로 C1은 faithful reference
> semantics로는 구현됐지만, 그대로 model checking target으로 쓰기는 어렵다고
> 보고드리는 게 맞겠습니다.

### P1. Confirm C1 Exit Criterion

Need professor decision:

- Should strict C1 itself be required to model-check from initial states, or is
  C1 allowed to be the faithful executable reference while C2 handles model
  checking?

This matters because strict generated C1 `step`/`steps` relation execution
works, but direct generated `step(C) => C'` model checking still explodes.

### P2. Start C2 From The Current C1

Likely C2 work:

- Heat/cool or focused evaluation contexts.
- Context split pruning.
- Canonicalization of semantically equivalent control contexts.
- Do not add benchmark-specific `dstep` rules to the C1 baseline.

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
rew [1000] in WASM-FIB-BS : step(fib-config(i32v(0))) .
search [1] in WASM-FIB-BS : steps(fib-config(i32v(0))) =>* (Z:State ; CTORCONSTA2(CTORI32A0, 0)) .
search [1] in WASM-FIB-BS : steps(fib-config(i32v(5))) =>* (Z:State ; CTORCONSTA2(CTORI32A0, 5)) .
red in WASM-FIB-BS-PROPS : modelCheck(mc(fib-config(i32v(0))), <> result-is(0)) .
```
