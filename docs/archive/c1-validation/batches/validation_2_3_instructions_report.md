# Validation 2.3 Instructions Strict C1 Report

## Scope

Source file: `wasm-3.0/2.3-validation.instructions.spectec`

Strict policy: one SpecTec source relation-rule target maps to one primary Maude `rl`/`crl`; no derived `iter-empty` or `opt-empty` validation rules are allowed.

## Counts

- Explicit active `rule` declarations: 138
- Relation-level `hint(show ...)` targets lowered as primary rules: 2 (`Defaultable`, `Nondefaultable`)
- Total 2.3 source relation-rule targets: 140
- Structurally matched to generated primary `crl`: 140
- Missing primary rules: 0
- Source targets still emitted as `eq`/`ceq ... = valid`: 0
- Derived `iter-empty` / `opt-empty` labels: 0
- Commented-out source rules not counted: `Instr_ok/load`, `Instr_ok/store`

## Source Targets And Generated Labels

| Source line | Source target | Generated label | Test status |
|---:|---|---|---|
| 9 | `Defaultable` | `defaultable-r0` | not-ground-testable-yet |
| 12 | `Nondefaultable` | `nondefaultable-r0` | not-ground-testable-yet |
| 18 | `Instr_ok/nop` | `instr-ok-nop` | executable-success |
| 21 | `Instr_ok/unreachable` | `instr-ok-unreachable` | executable-fail |
| 25 | `Instr_ok/drop` | `instr-ok-drop` | executable-success |
| 29 | `Instr_ok/select-expl` | `instr-ok-select-expl` | not-ground-testable-yet |
| 33 | `Instr_ok/select-impl` | `instr-ok-select-impl` | not-ground-testable-yet |
| 44 | `Blocktype_ok/valtype` | `blocktype-ok-valtype` | not-ground-testable-yet |
| 48 | `Blocktype_ok/typeidx` | `blocktype-ok-typeidx` | not-ground-testable-yet |
| 53 | `Instr_ok/block` | `instr-ok-block` | not-ground-testable-yet |
| 58 | `Instr_ok/loop` | `instr-ok-loop` | not-ground-testable-yet |
| 63 | `Instr_ok/if` | `instr-ok-w-if` | not-ground-testable-yet |
| 72 | `Instr_ok/br` | `instr-ok-br` | not-ground-testable-yet |
| 77 | `Instr_ok/br_if` | `instr-ok-br-if` | not-ground-testable-yet |
| 81 | `Instr_ok/br_table` | `instr-ok-br-table` | not-ground-testable-yet |
| 87 | `Instr_ok/br_on_null` | `instr-ok-br-on-null` | not-ground-testable-yet |
| 92 | `Instr_ok/br_on_non_null` | `instr-ok-br-on-non-null` | not-ground-testable-yet |
| 96 | `Instr_ok/br_on_cast` | `instr-ok-br-on-cast` | not-ground-testable-yet |
| 104 | `Instr_ok/br_on_cast_fail` | `instr-ok-br-on-cast-fail` | not-ground-testable-yet |
| 115 | `Instr_ok/call` | `instr-ok-call` | not-ground-testable-yet |
| 119 | `Instr_ok/call_ref` | `instr-ok-call-ref` | not-ground-testable-yet |
| 123 | `Instr_ok/call_indirect` | `instr-ok-call-indirect` | not-ground-testable-yet |
| 129 | `Instr_ok/return` | `instr-ok-return` | not-ground-testable-yet |
| 135 | `Instr_ok/return_call` | `instr-ok-return-call` | not-ground-testable-yet |
| 143 | `Instr_ok/return_call_ref` | `instr-ok-return-call-ref` | not-ground-testable-yet |
| 151 | `Instr_ok/return_call_indirect` | `instr-ok-return-call-indirect` | not-ground-testable-yet |
| 166 | `Instr_ok/throw` | `instr-ok-throw` | not-ground-testable-yet |
| 171 | `Instr_ok/throw_ref` | `instr-ok-throw-ref` | not-ground-testable-yet |
| 175 | `Instr_ok/try_table` | `instr-ok-try-table` | not-ground-testable-yet |
| 181 | `Catch_ok/catch` | `catch-ok-catch` | not-ground-testable-yet |
| 186 | `Catch_ok/catch_ref` | `catch-ok-catch-ref` | not-ground-testable-yet |
| 191 | `Catch_ok/catch_all` | `catch-ok-catch-all` | not-ground-testable-yet |
| 195 | `Catch_ok/catch_all_ref` | `catch-ok-catch-all-ref` | not-ground-testable-yet |
| 202 | `Instr_ok/ref.null` | `instr-ok-ref-null` | not-ground-testable-yet |
| 206 | `Instr_ok/ref.func` | `instr-ok-ref-func` | not-ground-testable-yet |
| 211 | `Instr_ok/ref.i31` | `instr-ok-ref-i31` | not-ground-testable-yet |
| 214 | `Instr_ok/ref.is_null` | `instr-ok-ref-is-null` | not-ground-testable-yet |
| 218 | `Instr_ok/ref.as_non_null` | `instr-ok-ref-as-non-null` | not-ground-testable-yet |
| 222 | `Instr_ok/ref.eq` | `instr-ok-ref-eq` | not-ground-testable-yet |
| 225 | `Instr_ok/ref.test` | `instr-ok-ref-test` | not-ground-testable-yet |
| 231 | `Instr_ok/ref.cast` | `instr-ok-ref-cast` | not-ground-testable-yet |
| 240 | `Instr_ok/i31.get` | `instr-ok-i31-get` | not-ground-testable-yet |
| 246 | `Instr_ok/struct.new` | `instr-ok-struct-new` | not-ground-testable-yet |
| 250 | `Instr_ok/struct.new_default` | `instr-ok-struct-new-default` | not-ground-testable-yet |
| 258 | `Instr_ok/struct.get` | `instr-ok-struct-get` | not-ground-testable-yet |
| 264 | `Instr_ok/struct.set` | `instr-ok-struct-set` | not-ground-testable-yet |
| 272 | `Instr_ok/array.new` | `instr-ok-array-new` | not-ground-testable-yet |
| 276 | `Instr_ok/array.new_default` | `instr-ok-array-new-default` | not-ground-testable-yet |
| 281 | `Instr_ok/array.new_fixed` | `instr-ok-array-new-fixed` | not-ground-testable-yet |
| 285 | `Instr_ok/array.new_elem` | `instr-ok-array-new-elem` | not-ground-testable-yet |
| 290 | `Instr_ok/array.new_data` | `instr-ok-array-new-data` | not-ground-testable-yet |
| 296 | `Instr_ok/array.get` | `instr-ok-array-get` | not-ground-testable-yet |
| 301 | `Instr_ok/array.set` | `instr-ok-array-set` | not-ground-testable-yet |
| 305 | `Instr_ok/array.len` | `instr-ok-array-len` | not-ground-testable-yet |
| 308 | `Instr_ok/array.fill` | `instr-ok-array-fill` | not-ground-testable-yet |
| 312 | `Instr_ok/array.copy` | `instr-ok-array-copy` | not-ground-testable-yet |
| 318 | `Instr_ok/array.init_elem` | `instr-ok-array-init-elem` | not-ground-testable-yet |
| 323 | `Instr_ok/array.init_data` | `instr-ok-array-init-data` | not-ground-testable-yet |
| 332 | `Instr_ok/extern.convert_any` | `instr-ok-extern-convert-any` | not-ground-testable-yet |
| 336 | `Instr_ok/any.convert_extern` | `instr-ok-any-convert-extern` | not-ground-testable-yet |
| 343 | `Instr_ok/local.get` | `instr-ok-local-get` | not-ground-testable-yet |
| 347 | `Instr_ok/local.set` | `instr-ok-local-set` | not-ground-testable-yet |
| 351 | `Instr_ok/local.tee` | `instr-ok-local-tee` | not-ground-testable-yet |
| 358 | `Instr_ok/global.get` | `instr-ok-global-get` | not-ground-testable-yet |
| 362 | `Instr_ok/global.set` | `instr-ok-global-set` | not-ground-testable-yet |
| 369 | `Instr_ok/table.get` | `instr-ok-table-get` | not-ground-testable-yet |
| 373 | `Instr_ok/table.set` | `instr-ok-table-set` | not-ground-testable-yet |
| 377 | `Instr_ok/table.size` | `instr-ok-table-size` | not-ground-testable-yet |
| 381 | `Instr_ok/table.grow` | `instr-ok-table-grow` | not-ground-testable-yet |
| 385 | `Instr_ok/table.fill` | `instr-ok-table-fill` | not-ground-testable-yet |
| 389 | `Instr_ok/table.copy` | `instr-ok-table-copy` | not-ground-testable-yet |
| 395 | `Instr_ok/table.init` | `instr-ok-table-init` | not-ground-testable-yet |
| 401 | `Instr_ok/elem.drop` | `instr-ok-elem-drop` | not-ground-testable-yet |
| 410 | `Memarg_ok` | `memarg-ok-r0` | not-ground-testable-yet |
| 416 | `Instr_ok/memory.size` | `instr-ok-memory-size` | not-ground-testable-yet |
| 420 | `Instr_ok/memory.grow` | `instr-ok-memory-grow` | not-ground-testable-yet |
| 424 | `Instr_ok/memory.fill` | `instr-ok-memory-fill` | not-ground-testable-yet |
| 428 | `Instr_ok/memory.copy` | `instr-ok-memory-copy` | not-ground-testable-yet |
| 433 | `Instr_ok/memory.init` | `instr-ok-memory-init` | not-ground-testable-yet |
| 438 | `Instr_ok/data.drop` | `instr-ok-data-drop` | not-ground-testable-yet |
| 451 | `Instr_ok/load-val` | `instr-ok-load-val` | not-ground-testable-yet |
| 456 | `Instr_ok/load-pack` | `instr-ok-load-pack` | not-ground-testable-yet |
| 470 | `Instr_ok/store-val` | `instr-ok-store-val` | not-ground-testable-yet |
| 475 | `Instr_ok/store-pack` | `instr-ok-store-pack` | not-ground-testable-yet |
| 480 | `Instr_ok/vload-val` | `instr-ok-vload-val` | not-ground-testable-yet |
| 485 | `Instr_ok/vload-pack` | `instr-ok-vload-pack` | not-ground-testable-yet |
| 490 | `Instr_ok/vload-splat` | `instr-ok-vload-splat` | not-ground-testable-yet |
| 495 | `Instr_ok/vload-zero` | `instr-ok-vload-zero` | not-ground-testable-yet |
| 500 | `Instr_ok/vload_lane` | `instr-ok-vload-lane` | not-ground-testable-yet |
| 506 | `Instr_ok/vstore` | `instr-ok-vstore` | not-ground-testable-yet |
| 511 | `Instr_ok/vstore_lane` | `instr-ok-vstore-lane` | not-ground-testable-yet |
| 520 | `Instr_ok/const` | `instr-ok-const` | not-ground-testable-yet |
| 523 | `Instr_ok/unop` | `instr-ok-unop` | not-ground-testable-yet |
| 526 | `Instr_ok/binop` | `instr-ok-binop` | not-ground-testable-yet |
| 529 | `Instr_ok/testop` | `instr-ok-testop` | not-ground-testable-yet |
| 532 | `Instr_ok/relop` | `instr-ok-relop` | not-ground-testable-yet |
| 535 | `Instr_ok/cvtop` | `instr-ok-cvtop` | not-ground-testable-yet |
| 541 | `Instr_ok/vconst` | `instr-ok-vconst` | not-ground-testable-yet |
| 544 | `Instr_ok/vvunop` | `instr-ok-vvunop` | not-ground-testable-yet |
| 547 | `Instr_ok/vvbinop` | `instr-ok-vvbinop` | not-ground-testable-yet |
| 550 | `Instr_ok/vvternop` | `instr-ok-vvternop` | not-ground-testable-yet |
| 553 | `Instr_ok/vvtestop` | `instr-ok-vvtestop` | not-ground-testable-yet |
| 556 | `Instr_ok/vunop` | `instr-ok-vunop` | not-ground-testable-yet |
| 559 | `Instr_ok/vbinop` | `instr-ok-vbinop` | not-ground-testable-yet |
| 562 | `Instr_ok/vternop` | `instr-ok-vternop` | not-ground-testable-yet |
| 565 | `Instr_ok/vtestop` | `instr-ok-vtestop` | not-ground-testable-yet |
| 568 | `Instr_ok/vrelop` | `instr-ok-vrelop` | not-ground-testable-yet |
| 571 | `Instr_ok/vshiftop` | `instr-ok-vshiftop` | not-ground-testable-yet |
| 574 | `Instr_ok/vbitmask` | `instr-ok-vbitmask` | not-ground-testable-yet |
| 577 | `Instr_ok/vswizzlop` | `instr-ok-vswizzlop` | not-ground-testable-yet |
| 580 | `Instr_ok/vshuffle` | `instr-ok-vshuffle` | not-ground-testable-yet |
| 584 | `Instr_ok/vsplat` | `instr-ok-vsplat` | not-ground-testable-yet |
| 587 | `Instr_ok/vextract_lane` | `instr-ok-vextract-lane` | not-ground-testable-yet |
| 591 | `Instr_ok/vreplace_lane` | `instr-ok-vreplace-lane` | not-ground-testable-yet |
| 595 | `Instr_ok/vextunop` | `instr-ok-vextunop` | not-ground-testable-yet |
| 598 | `Instr_ok/vextbinop` | `instr-ok-vextbinop` | not-ground-testable-yet |
| 601 | `Instr_ok/vextternop` | `instr-ok-vextternop` | not-ground-testable-yet |
| 604 | `Instr_ok/vnarrow` | `instr-ok-vnarrow` | not-ground-testable-yet |
| 607 | `Instr_ok/vcvtop` | `instr-ok-vcvtop` | not-ground-testable-yet |
| 613 | `Instrs_ok/empty` | `instrs-ok-empty` | executable-success |
| 617 | `Instrs_ok/seq` | `instrs-ok-seq` | executable-fail |
| 623 | `Instrs_ok/sub` | `instrs-ok-sub` | known-limitation |
| 630 | `Instrs_ok/frame` | `instrs-ok-frame` | known-limitation |
| 638 | `Expr_ok` | `expr-ok-r0` | known-limitation |
| 649 | `Instr_const/const` | `instr-const-const` | executable-success |
| 652 | `Instr_const/vconst` | `instr-const-vconst` | not-ground-testable-yet |
| 655 | `Instr_const/ref.null` | `instr-const-ref-null` | not-ground-testable-yet |
| 658 | `Instr_const/ref.i31` | `instr-const-ref-i31` | not-ground-testable-yet |
| 661 | `Instr_const/ref.func` | `instr-const-ref-func` | not-ground-testable-yet |
| 664 | `Instr_const/struct.new` | `instr-const-struct-new` | not-ground-testable-yet |
| 667 | `Instr_const/struct.new_default` | `instr-const-struct-new-default` | not-ground-testable-yet |
| 670 | `Instr_const/array.new` | `instr-const-array-new` | not-ground-testable-yet |
| 673 | `Instr_const/array.new_default` | `instr-const-array-new-default` | not-ground-testable-yet |
| 676 | `Instr_const/array.new_fixed` | `instr-const-array-new-fixed` | not-ground-testable-yet |
| 679 | `Instr_const/any.convert_extern` | `instr-const-any-convert-extern` | not-ground-testable-yet |
| 682 | `Instr_const/extern.convert_any` | `instr-const-extern-convert-any` | not-ground-testable-yet |
| 685 | `Instr_const/global.get` | `instr-const-global-get` | not-ground-testable-yet |
| 689 | `Instr_const/binop` | `instr-const-binop` | not-ground-testable-yet |
| 695 | `Expr_const` | `expr-const-r0` | executable-success |
| 699 | `Expr_ok_const` | `expr-ok-const-r0` | known-limitation |

## Concrete Tests

Used the existing concrete empty context:

```maude
{item('TYPES, eps) ; item('RECS, eps) ; item('TAGS, eps) ;
 item('GLOBALS, eps) ; item('MEMS, eps) ; item('TABLES, eps) ;
 item('FUNCS, eps) ; item('DATAS, eps) ; item('ELEMS, eps) ;
 item('LOCALS, eps) ; item('LABELS, eps) ; item('RETURN, eps) ;
 item('REFS, eps)}
```

### Succeeded

- `Instr_ok/nop` / `instr-ok-nop`: `rew [100] in WASM-FIB-BS : Instr-ok(CONCRETE-CONTEXT, CTORNOPA0, CTORARROWA3(eps, eps, eps)) .` -> valid
- `Instr_ok/drop` / `instr-ok-drop`: `rew [100] in WASM-FIB-BS : Instr-ok(CONCRETE-CONTEXT, CTORDROPA0, CTORARROWA3(CTORI32A0, eps, eps)) .` -> valid
- `Instrs_ok/empty` / `instrs-ok-empty`: `rew [100] in WASM-FIB-BS : Instrs-ok(CONCRETE-CONTEXT, eps, CTORARROWA3(eps, eps, eps)) .` -> valid
- `Instr_const/const` / `instr-const-const`: `rew [100] in WASM-FIB-BS : Instr-const(CONCRETE-CONTEXT, CTORCONSTA2(CTORI32A0, 0)) .` -> valid
- `Expr_const` / `expr-const-r0`: `rew [100] in WASM-FIB-BS : Expr-const(CONCRETE-CONTEXT, CTORCONSTA2(CTORI32A0, 0)) .` -> valid

### Failed / Stuck

- `Instr_ok/unreachable` / `instr-ok-unreachable`: `rew [100] in WASM-FIB-BS : Instr-ok(CONCRETE-CONTEXT, CTORUNREACHABLEA0, CTORARROWA3(eps, eps, eps)) .` -> stuck Instr-ok(CONCRETE-CONTEXT, CTORUNREACHABLEA0, CTORARROWA3(eps, eps, eps))

  Reason: Blocking premise is Instrtype-ok(C, CTORARROWA3(eps, eps, eps)) => valid, which is a known strict empty-* limitation.

  Limitation: Depends on Instrtype-ok empty arrow; no iter-empty/list rule is allowed in strict C1.

- `Instrs_ok/seq` / `instrs-ok-seq`: `rew [1000] in WASM-FIB-BS : Instrs-ok(CONCRETE-CONTEXT, CTORNOPA0, CTORARROWA3(eps, eps, eps)) .` -> stuck Instrs-ok(CONCRETE-CONTEXT, CTORNOPA0, CTORARROWA3(eps, eps, eps))

  Reason: The singleton case needs Instrs_ok/seq. Its first condition is an output-bearing local-index assignment INITS TS := index(value(LOCALS,C), XS1); for the empty locals/empty x* case this reduces to stuck index(eps, eps). The rule also contains intermediate witness TS2 between Instr-ok and recursive Instrs-ok premises.

  Limitation: Known strict witness/output-bearing premise limitation; fixing execution would require mode-aware witness solving or helper control, not a derived validation rule.

## Known Untested Limitations In This File

- `Instrs_ok/sub` / `instrs-ok-sub`: Delegates to Instrtype-sub/Instrtype-ok; empty-arrow cases are known strict limitations.
- `Instrs_ok/frame` / `instrs-ok-frame`: Depends on recursive Instrs-ok plus Resulttype-ok over a valtype* prefix; empty/list cases may expose strict iteration limits.
- `Expr_ok` / `expr-ok-r0`: Delegates to Instrs-ok; inherits Instrs_ok/seq witness and empty-list limitations.
- `Expr_ok_const` / `expr-ok-const-r0`: Delegates to Expr-ok and Expr-const; inherits Expr-ok/Instrs-ok limitations.

## Generator Changes

No translator change was made in this 2.3 batch. No generated Maude was patched manually.

## Verification

- `grep -n "iter-empty\|opt-empty" output_bs.maude`: no results.
- Remaining `eq`/`ceq ... = valid`: footer/executable leftovers only: `Expand`, `Num-ok`, `Val-ok`.
- All 140 source relation-rule targets from `2.3-validation.instructions.spectec` have exactly one generated primary `crl`.

## Limitations To Ask About

- Whether strict C1 should intentionally leave `Instrs_ok/seq` non-executable when its intermediate `TS2` and local-index output premise require mode-aware witness synthesis.
- Whether empty locals indexing (`index(eps, eps)`) should remain documented as an execution limitation or be handled by a generic DecD/list helper in a later, non-derived way.
- Whether relation-level `hint(show ...)` targets such as `Defaultable` and `Nondefaultable` should be counted alongside explicit `rule` declarations in the strict source-target total.

## Next Recommended Batch

Continue with `wasm-3.0/2.4-validation.modules.spectec`, while keeping Module-ok/init-config construction out of scope unless explicitly requested.
