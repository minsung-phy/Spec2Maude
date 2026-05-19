# Remaining 21 Strict Targets: 4.1 Values And Eval_expr

## Scope

This audit covers the 20 remaining source targets from `wasm-3.0/4.1-execution.values.spectec` plus `Eval_expr` from `wasm-3.0/4.3-execution.instructions.spectec`. `Defaultable` and `Nondefaultable` are not counted here because they were already counted with the generated instruction-validation block.

## Counts

- Remaining target count: 21
- Structurally matched to generated primary `crl`: 21
- Missing primary rules: 0
- Source targets still emitted as `eq`/`ceq ... = valid`: 0
- Derived `iter-empty` / `opt-empty` labels: 0
- Cumulative strict coverage after this batch: 281 / 281

## Source Targets And Generated Labels

| Source file | Source line | Source rule | Generated label | Test status |
|---|---:|---|---|---|
| `wasm-3.0/4.1-execution.values.spectec` | 28 | `Num_ok` | `num-ok-r0` | executable-success |
| `wasm-3.0/4.1-execution.values.spectec` | 31 | `Vec_ok` | `vec-ok-r0` | executable-success |
| `wasm-3.0/4.1-execution.values.spectec` | 35 | `Ref_ok/null` | `ref-ok-null` | executable-success |
| `wasm-3.0/4.1-execution.values.spectec` | 39 | `Ref_ok/i31` | `ref-ok-i31` | executable-success |
| `wasm-3.0/4.1-execution.values.spectec` | 42 | `Ref_ok/struct` | `ref-ok-struct` | known-limitation |
| `wasm-3.0/4.1-execution.values.spectec` | 46 | `Ref_ok/array` | `ref-ok-array` | known-limitation |
| `wasm-3.0/4.1-execution.values.spectec` | 50 | `Ref_ok/func` | `ref-ok-func` | known-limitation |
| `wasm-3.0/4.1-execution.values.spectec` | 54 | `Ref_ok/exn` | `ref-ok-exn` | known-limitation |
| `wasm-3.0/4.1-execution.values.spectec` | 58 | `Ref_ok/host` | `ref-ok-host` | executable-success |
| `wasm-3.0/4.1-execution.values.spectec` | 61 | `Ref_ok/extern` | `ref-ok-extern` | known-limitation |
| `wasm-3.0/4.1-execution.values.spectec` | 65 | `Ref_ok/sub` | `ref-ok-sub` | known-limitation |
| `wasm-3.0/4.1-execution.values.spectec` | 71 | `Val_ok/num` | `val-ok-num` | executable-success |
| `wasm-3.0/4.1-execution.values.spectec` | 75 | `Val_ok/vec` | `val-ok-vec` | executable-success |
| `wasm-3.0/4.1-execution.values.spectec` | 79 | `Val_ok/ref` | `val-ok-ref` | known-limitation |
| `wasm-3.0/4.1-execution.values.spectec` | 88 | `Externaddr_ok/tag` | `externaddr-ok-tag` | known-limitation |
| `wasm-3.0/4.1-execution.values.spectec` | 92 | `Externaddr_ok/global` | `externaddr-ok-global` | known-limitation |
| `wasm-3.0/4.1-execution.values.spectec` | 96 | `Externaddr_ok/mem` | `externaddr-ok-mem` | known-limitation |
| `wasm-3.0/4.1-execution.values.spectec` | 100 | `Externaddr_ok/table` | `externaddr-ok-table` | known-limitation |
| `wasm-3.0/4.1-execution.values.spectec` | 104 | `Externaddr_ok/func` | `externaddr-ok-func` | executable-fail |
| `wasm-3.0/4.1-execution.values.spectec` | 108 | `Externaddr_ok/sub` | `externaddr-ok-sub` | known-limitation |
| `wasm-3.0/4.3-execution.instructions.spectec` | 1113 | `Eval_expr` | `eval-expr-r0` | executable-success |

## Concrete Tests

### Succeeded

- `Num_ok` / `num-ok-r0`: `rew [100] in WASM-FIB-BS : Num-ok(fib-store, CTORCONSTA2(CTORI32A0, 7), CTORI32A0) .` -> valid
- `Vec_ok` / `vec-ok-r0`: `rew [100] in WASM-FIB-BS : Vec-ok(fib-store, CTORVCONSTA2(CTORV128A0, 0), CTORV128A0) .` -> valid
- `Ref_ok/null` / `ref-ok-null`: `rew [100] in WASM-FIB-BS : Ref-ok(fib-store, CTORREFNULLA1(CTORI31A0), CTORREFA2(CTORNULLA0, CTORI31A0)) .` -> valid
- `Ref_ok/i31` / `ref-ok-i31`: `rew [100] in WASM-FIB-BS : Ref-ok(fib-store, CTORREFI31NUMA1(0), CTORREFA2(eps, CTORI31A0)) .` -> valid
- `Ref_ok/host` / `ref-ok-host`: `rew [100] in WASM-FIB-BS : Ref-ok(fib-store, CTORREFHOSTADDRA1(0), CTORREFA2(eps, CTORANYA0)) .` -> valid
- `Val_ok/num` / `val-ok-num`: `rew [100] in WASM-FIB-BS : Val-ok(fib-store, CTORCONSTA2(CTORI32A0, 7), CTORI32A0) .` -> valid
- `Val_ok/vec` / `val-ok-vec`: `rew [100] in WASM-FIB-BS : Val-ok(fib-store, CTORVCONSTA2(CTORV128A0, 0), CTORV128A0) .` -> valid
- `Eval_expr` / `eval-expr-r0`: `rew [100] in WASM-FIB-BS : Eval-expr((fib-store ; empty-frame).State, CTORCONSTA2(CTORI32A0, 7), (fib-store ; empty-frame).State, CTORCONSTA2(CTORI32A0, 7)) .` -> valid

### Failed / Stuck

- `Externaddr_ok/func` / `externaddr-ok-func`: `rew [100] in WASM-FIB-BS : Externaddr-ok(fib-store, CTORFUNCA1(0), CTORFUNCA1(fib-type)) .` -> stuck Externaddr-ok(fib-store, CTORFUNCA1(0), CTORFUNCA1(fib-type))

  Reason: The source rule requires index(value(FUNCS, s), a) to be a funcinst whose TYPE projects to the expected deftype. The concrete fib-store has a hand-written store representation; the rule did not discharge as a ground rewrite in this probe. This is a concrete store-shape/executable lookup limitation, not a missing primary rule.

  Limitation: Needs concrete store/funcinst facts in a shape the source rule can consume; no helper patch added.

## Known Untested Limitations

- `Ref_ok/struct` / `ref-ok-struct`: Depends on store STRUCTS lookup and TYPE projection.
- `Ref_ok/array` / `ref-ok-array`: Depends on store ARRAYS lookup and TYPE projection.
- `Ref_ok/func` / `ref-ok-func`: Depends on store FUNCS lookup and TYPE projection.
- `Ref_ok/exn` / `ref-ok-exn`: Depends on store EXNS lookup.
- `Ref_ok/extern` / `ref-ok-extern`: Delegates to Ref-ok over an addrref; concrete addrref/store shape needed.
- `Ref_ok/sub` / `ref-ok-sub`: Contains recursive Ref-ok premise plus Reftype-sub premise; may need witness choice for rt'.
- `Val_ok/ref` / `val-ok-ref`: Delegates to Ref-ok; concrete ref/store shape needed.
- `Externaddr_ok/tag` / `externaddr-ok-tag`: Depends on store TAGS lookup and taginst TYPE projection.
- `Externaddr_ok/global` / `externaddr-ok-global`: Depends on store GLOBALS lookup and globalinst TYPE projection.
- `Externaddr_ok/mem` / `externaddr-ok-mem`: Depends on store MEMS lookup and meminst TYPE projection.
- `Externaddr_ok/table` / `externaddr-ok-table`: Depends on store TABLES lookup and tableinst TYPE projection.
- `Externaddr_ok/sub` / `externaddr-ok-sub`: Contains recursive Externaddr-ok premise plus Externtype-sub premise; may need witness choice for xt'.

## Footer / Equation Interactions

The source-generated primary `crl`s for `Num-ok` and `Val-ok` exist and are counted. The remaining `eq`/`ceq ... = valid` forms at the footer are executable leftovers only: one `Expand`, one `Num-ok`, and four `Val-ok` equations. They are not counted as source-target primary rules and do not indicate missing source lowering.

## Generator Changes

No translator change was made in this final 21-target audit. No generated Maude was patched manually.

## Verification

- `grep -n "iter-empty\|opt-empty" output_bs.maude`: no results.
- Remaining `eq`/`ceq ... = valid`: footer/executable leftovers only: `Expand`, `Num-ok`, `Val-ok`.
- `validation_281_progress.csv` now has 281 source-target rows with unique generated labels.

## Recommended Next Step

Freeze the strict C1 validation-lowering status note: structural coverage is complete at 281 / 281, while executability limitations should remain documented separately from C1 isomorphism.
