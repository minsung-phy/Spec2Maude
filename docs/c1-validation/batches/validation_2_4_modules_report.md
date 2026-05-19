# Validation 2.4 Modules Strict C1 Report

## Scope

Source file: `wasm-3.0/2.4-validation.modules.spectec`

This pass checks strict source-rule to primary `rl`/`crl` structure for module validation. It does not attempt Module-ok/init-config construction.

## Counts

- Source rules in 2.4: 28
- Structurally matched to generated primary `crl`: 28
- Missing primary rules: 0
- Source rules still emitted as `eq`/`ceq ... = valid`: 0
- Derived `iter-empty` / `opt-empty` labels: 0

## Source Rules And Generated Labels

| Source line | Source rule | Generated label | Structural status | Test status |
|---:|---|---|---|---|
| 20 | `Type_ok` | `type-ok-r0` | structurally-suspicious | known-limitation |
| 26 | `Tag_ok` | `tag-ok-r0` | structurally-isomorphic | not-ground-testable-yet |
| 30 | `Global_ok` | `global-ok-r0` | structurally-suspicious | executable-fail |
| 36 | `Mem_ok` | `mem-ok-r0` | structurally-isomorphic | executable-success |
| 40 | `Table_ok` | `table-ok-r0` | structurally-suspicious | known-limitation |
| 46 | `Local_ok/set` | `local-ok-set` | structurally-isomorphic | executable-success |
| 50 | `Local_ok/unset` | `local-ok-unset` | structurally-isomorphic | not-ground-testable-yet |
| 54 | `Func_ok` | `func-ok-r0` | structurally-suspicious | known-limitation |
| 61 | `Data_ok` | `data-ok-r0` | structurally-isomorphic | executable-success |
| 65 | `Elem_ok` | `elem-ok-r0` | structurally-suspicious | known-limitation |
| 71 | `Datamode_ok/passive` | `datamode-ok-passive` | structurally-isomorphic | executable-success |
| 74 | `Datamode_ok/active` | `datamode-ok-active` | structurally-suspicious | known-limitation |
| 79 | `Elemmode_ok/passive` | `elemmode-ok-passive` | structurally-isomorphic | not-ground-testable-yet |
| 82 | `Elemmode_ok/declare` | `elemmode-ok-declare` | structurally-isomorphic | not-ground-testable-yet |
| 85 | `Elemmode_ok/active` | `elemmode-ok-active` | structurally-suspicious | known-limitation |
| 91 | `Start_ok` | `start-ok-r0` | structurally-suspicious | known-limitation |
| 102 | `Import_ok` | `import-ok-r0` | structurally-suspicious | known-limitation |
| 106 | `Export_ok` | `export-ok-r0` | structurally-suspicious | known-limitation |
| 111 | `Externidx_ok/tag` | `externidx-ok-tag` | structurally-isomorphic | not-ground-testable-yet |
| 115 | `Externidx_ok/global` | `externidx-ok-global` | structurally-isomorphic | not-ground-testable-yet |
| 119 | `Externidx_ok/mem` | `externidx-ok-mem` | structurally-isomorphic | not-ground-testable-yet |
| 123 | `Externidx_ok/table` | `externidx-ok-table` | structurally-isomorphic | not-ground-testable-yet |
| 127 | `Externidx_ok/func` | `externidx-ok-func` | structurally-isomorphic | not-ground-testable-yet |
| 143 | `Module_ok` | `module-ok-r0` | structurally-suspicious | known-limitation |
| 172 | `Types_ok/empty` | `types-ok-empty` | structurally-isomorphic | executable-success |
| 175 | `Types_ok/cons` | `types-ok-cons` | structurally-suspicious | known-limitation |
| 180 | `Globals_ok/empty` | `globals-ok-empty` | structurally-isomorphic | executable-success |
| 183 | `Globals_ok/cons` | `globals-ok-cons` | structurally-suspicious | known-limitation |

## Concrete Tests

Used the existing concrete empty context.

### Succeeded

- `Mem_ok` / `mem-ok-r0`: `rew [100] in WASM-FIB-BS : Mem-ok(CONCRETE-CONTEXT, CTORMEMORYA1(CTORPAGEA2(CTORI32A0, CTORLBRACKDOTDOTRBRACKA2(0, 1))), CTORPAGEA2(CTORI32A0, CTORLBRACKDOTDOTRBRACKA2(0, 1))) .` -> valid
- `Local_ok/set` / `local-ok-set`: `rew [100] in WASM-FIB-BS : Local-ok(CONCRETE-CONTEXT, CTORLOCALA1(CTORI32A0), CTORSETA0 CTORI32A0) .` -> valid
- `Data_ok` / `data-ok-r0`: `rew [100] in WASM-FIB-BS : Data-ok(CONCRETE-CONTEXT, CTORDATAA2(eps, CTORPASSIVEA0), CTOROKA0) .` -> valid
- `Datamode_ok/passive` / `datamode-ok-passive`: `rew [100] in WASM-FIB-BS : Datamode-ok(CONCRETE-CONTEXT, CTORPASSIVEA0, CTOROKA0) .` -> valid
- `Types_ok/empty` / `types-ok-empty`: `rew [100] in WASM-FIB-BS : Types-ok(CONCRETE-CONTEXT, eps, eps) .` -> valid
- `Globals_ok/empty` / `globals-ok-empty`: `rew [100] in WASM-FIB-BS : Globals-ok(CONCRETE-CONTEXT, eps, eps) .` -> valid

### Failed / Stuck

- `Global_ok` / `global-ok-r0`: `rew [100] in WASM-FIB-BS : Global-ok(CONCRETE-CONTEXT, CTORGLOBALA2(CTORMUTA0 CTORI32A0, CTORCONSTA2(CTORI32A0, 0)), CTORMUTA0 CTORI32A0) .` -> stuck Global-ok(CONCRETE-CONTEXT, CTORGLOBALA2(CTORMUTA0 CTORI32A0, CTORCONSTA2(CTORI32A0, 0)), CTORMUTA0 CTORI32A0)

  Reason: Globaltype-ok succeeds for the mutable i32 type, but Expr-ok-const(C, CTORCONSTA2(CTORI32A0, 0), CTORI32A0) is stuck. That premise delegates to Expr-ok/Instrs-ok for a singleton instruction list, which hits the known Instrs_ok/seq output-bearing local-index/witness issue.

  Limitation: Inherits Expr-ok/Instrs-ok strict executability limitation; no derived validation rule or helper shortcut was added.

## Known Untested Limitations In This File

- `Type_ok` / `type-ok-r0`: Depends on Rectype-ok and $rolldt; recursive type validation can expose recursive/witness limits.
- `Table_ok` / `table-ok-r0`: Depends on Tabletype-ok and Expr-ok-const; inherits expression validation limits.
- `Func_ok` / `func-ok-r0`: Depends on Local-ok over local* and Expr-ok over the function body; inherits empty/list and Instrs_ok/seq witness limitations.
- `Elem_ok` / `elem-ok-r0`: Depends on Expr-ok-const over expr* and Elemmode-ok; expression-list validation inherits strict iteration limitations.
- `Datamode_ok/active` / `datamode-ok-active`: Depends on memory context lookup and Expr-ok-const; can expose index/Expr-ok limitations.
- `Elemmode_ok/active` / `elemmode-ok-active`: Depends on table lookup, Reftype-sub, and Expr-ok-const; can expose index and expression validation limitations.
- `Start_ok` / `start-ok-r0`: Depends on indexed function type expansion from C.FUNCS[x].
- `Import_ok` / `import-ok-r0`: Delegates to Externtype-ok; simple only with concrete name/externtype terms.
- `Export_ok` / `export-ok-r0`: Delegates to Externidx-ok and context lookup.
- `Module_ok` / `module-ok-r0`: Large structural rule with many iterated premises, optional start, output witnesses, and context synthesis; intentionally not an init-config/executability target in this pass.
- `Types_ok/cons` / `types-ok-cons`: Recursive list rule with output sequence dt_1* dt*; can expose recursive list validation limits.
- `Globals_ok/cons` / `globals-ok-cons`: Recursive list rule over globals; Global-ok inherits Expr-ok-const limitations.

## Generator Changes

No translator change was made in this 2.4 batch. No generated Maude was patched manually.

## Verification

- `grep -n "iter-empty\|opt-empty" output_bs.maude`: no results.
- Remaining `eq`/`ceq ... = valid`: footer/executable leftovers only: `Expand`, `Num-ok`, `Val-ok`.
- All 28 source rules from `2.4-validation.modules.spectec` have exactly one generated primary `crl`.

## Cumulative Summary

- 2.1: 42 structural matches
- 2.2: 50 structural matches
- 2.3: 140 structural matches
- 2.4: 28 structural matches
- Cumulative 2.1 through 2.4: 260 structural matches
- This does not reach the strict total 281. The remaining 21 source targets are outside the 2.x validation files: 20 from `4.1-execution.values.spectec` (`Num_ok`, `Vec_ok`, `Ref_ok`, `Val_ok`, `Externaddr_ok`) plus `Eval_expr` from `4.3-execution.instructions.spectec`.

Remaining 21 labels to audit separately:

- `num-ok-r0`
- `vec-ok-r0`
- `ref-ok-null`
- `ref-ok-i31`
- `ref-ok-struct`
- `ref-ok-array`
- `ref-ok-func`
- `ref-ok-exn`
- `ref-ok-host`
- `ref-ok-extern`
- `ref-ok-sub`
- `val-ok-num`
- `val-ok-vec`
- `val-ok-ref`
- `externaddr-ok-tag`
- `externaddr-ok-global`
- `externaddr-ok-mem`
- `externaddr-ok-table`
- `externaddr-ok-func`
- `externaddr-ok-sub`
- `eval-expr-r0`

## Limitations To Ask About

- Whether `Module_ok` should remain a purely structural strict-C1 rule until C2/execution-oriented control can address its many iterated premises and output witnesses.
- Whether expression validation for constant global/table initializers should stay stuck through `Expr-ok`/`Instrs-ok/seq`, or whether a later phase should introduce non-C1 execution control.
- Whether the remaining 21 non-2.x source targets should be audited as a separate “runtime validation/value judgement” batch after 2.4.

## Next Recommended Step

Audit the remaining 21 non-2.x source targets as a final strict-count reconciliation batch, then freeze the C1 strict validation-lowering status note.
