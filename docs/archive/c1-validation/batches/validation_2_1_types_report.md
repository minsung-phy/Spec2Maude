# Validation 2.1 Types Report

## Scope
Source file: `wasm-3.0/2.1-validation.types.spectec`.

## Rule Map
| # | source rule | generated label | structural status | test status |
|---:|---|---|---|---|
| 1 | `Numtype-ok` | `numtype-ok-r0` | structurally-isomorphic | executable-success |
| 2 | `Vectype-ok` | `vectype-ok-r0` | structurally-isomorphic | executable-success |
| 3 | `Heaptype-ok/abs` | `heaptype-ok-abs` | structurally-isomorphic | executable-success |
| 4 | `Heaptype-ok/typeuse` | `heaptype-ok-typeuse` | structurally-isomorphic | not-ground-testable-yet |
| 5 | `Reftype-ok` | `reftype-ok-r0` | structurally-isomorphic | executable-success |
| 6 | `Valtype-ok/num` | `valtype-ok-num` | structurally-isomorphic | executable-success |
| 7 | `Valtype-ok/vec` | `valtype-ok-vec` | structurally-isomorphic | executable-success |
| 8 | `Valtype-ok/ref` | `valtype-ok-ref` | structurally-isomorphic | executable-success |
| 9 | `Valtype-ok/bot` | `valtype-ok-bot` | structurally-isomorphic | executable-success |
| 10 | `Resulttype-ok` | `resulttype-ok-r0` | structurally-suspicious | executable-fail |
| 11 | `Instrtype-ok` | `instrtype-ok-r0` | structurally-suspicious | executable-fail |
| 12 | `Expand` | `expand-r0` | structurally-isomorphic | not-ground-testable-yet |
| 13 | `Expand-use/deftype` | `expand-use-deftype` | structurally-isomorphic | not-ground-testable-yet |
| 14 | `Expand-use/typeidx` | `expand-use-typeidx` | structurally-isomorphic | not-ground-testable-yet |
| 15 | `Typeuse-ok/typeidx` | `typeuse-ok-typeidx` | structurally-isomorphic | not-ground-testable-yet |
| 16 | `Typeuse-ok/rec` | `typeuse-ok-rec` | structurally-isomorphic | not-ground-testable-yet |
| 17 | `Typeuse-ok/deftype` | `typeuse-ok-deftype` | structurally-isomorphic | not-ground-testable-yet |
| 18 | `Packtype-ok` | `packtype-ok-r0` | structurally-isomorphic | executable-success |
| 19 | `Storagetype-ok/val` | `storagetype-ok-val` | structurally-isomorphic | executable-success |
| 20 | `Storagetype-ok/pack` | `storagetype-ok-pack` | structurally-isomorphic | executable-success |
| 21 | `Fieldtype-ok` | `fieldtype-ok-r0` | structurally-isomorphic | not-ground-testable-yet |
| 22 | `Comptype-ok/struct` | `comptype-ok-struct` | structurally-suspicious | not-ground-testable-yet |
| 23 | `Comptype-ok/array` | `comptype-ok-array` | structurally-isomorphic | not-ground-testable-yet |
| 24 | `Comptype-ok/func` | `comptype-ok-func` | structurally-isomorphic | not-ground-testable-yet |
| 25 | `Subtype-ok` | `subtype-ok-r0` | structurally-suspicious | not-ground-testable-yet |
| 26 | `Subtype-ok2` | `subtype-ok2-r0` | structurally-suspicious | not-ground-testable-yet |
| 27 | `Rectype-ok/empty` | `rectype-ok-empty` | structurally-isomorphic | not-ground-testable-yet |
| 28 | `Rectype-ok/cons` | `rectype-ok-cons` | structurally-isomorphic | not-ground-testable-yet |
| 29 | `Rectype-ok/_rec2` | `rectype-ok-w--rec2` | structurally-isomorphic | not-ground-testable-yet |
| 30 | `Rectype-ok2/empty` | `rectype-ok2-empty` | structurally-isomorphic | not-ground-testable-yet |
| 31 | `Rectype-ok2/cons` | `rectype-ok2-cons` | structurally-isomorphic | not-ground-testable-yet |
| 32 | `Deftype-ok` | `deftype-ok-r0` | structurally-isomorphic | not-ground-testable-yet |
| 33 | `Limits-ok` | `limits-ok-r0` | structurally-suspicious | not-ground-testable-yet |
| 34 | `Tagtype-ok` | `tagtype-ok-r0` | structurally-isomorphic | not-ground-testable-yet |
| 35 | `Globaltype-ok` | `globaltype-ok-r0` | structurally-isomorphic | not-ground-testable-yet |
| 36 | `Memtype-ok` | `memtype-ok-r0` | structurally-isomorphic | not-ground-testable-yet |
| 37 | `Tabletype-ok` | `tabletype-ok-r0` | structurally-isomorphic | not-ground-testable-yet |
| 38 | `Externtype-ok/tag` | `externtype-ok-tag` | structurally-isomorphic | not-ground-testable-yet |
| 39 | `Externtype-ok/global` | `externtype-ok-global` | structurally-isomorphic | not-ground-testable-yet |
| 40 | `Externtype-ok/mem` | `externtype-ok-mem` | structurally-isomorphic | not-ground-testable-yet |
| 41 | `Externtype-ok/table` | `externtype-ok-table` | structurally-isomorphic | not-ground-testable-yet |
| 42 | `Externtype-ok/func` | `externtype-ok-func` | structurally-isomorphic | not-ground-testable-yet |

## Counts
- Source rules in 2.1: 42
- Structurally matched to generated primary `rl/crl`: 42
- structurally-isomorphic: 36
- structurally-suspicious: 6
- executable-fail: 2
- executable-success: 11
- not-ground-testable-yet: 29

## Successful Concrete Tests
- `Numtype-ok` / `numtype-ok-r0`: `rew [100] in WASM-FIB-BS : Numtype-ok(CONCRETE-CONTEXT, CTORI32A0) .` -> valid
- `Vectype-ok` / `vectype-ok-r0`: `rew [100] in WASM-FIB-BS : Vectype-ok(CONCRETE-CONTEXT, CTORV128A0) .` -> valid
- `Heaptype-ok/abs` / `heaptype-ok-abs`: `rew [100] in WASM-FIB-BS : Heaptype-ok(CONCRETE-CONTEXT, CTORI31A0) .` -> valid
- `Reftype-ok` / `reftype-ok-r0`: `rew [100] in WASM-FIB-BS : Reftype-ok(CONCRETE-CONTEXT, CTORREFA2(CTORNULLA0, CTORI31A0)) .` -> valid
- `Valtype-ok/num` / `valtype-ok-num`: `rew [100] in WASM-FIB-BS : Valtype-ok(CONCRETE-CONTEXT, CTORI32A0) .` -> valid
- `Valtype-ok/vec` / `valtype-ok-vec`: `rew [100] in WASM-FIB-BS : Valtype-ok(CONCRETE-CONTEXT, CTORV128A0) .` -> valid
- `Valtype-ok/ref` / `valtype-ok-ref`: `rew [100] in WASM-FIB-BS : Valtype-ok(CONCRETE-CONTEXT, CTORREFA2(CTORNULLA0, CTORI31A0)) .` -> valid
- `Valtype-ok/bot` / `valtype-ok-bot`: `rew [100] in WASM-FIB-BS : Valtype-ok(CONCRETE-CONTEXT, CTORBOTA0) .` -> valid
- `Packtype-ok` / `packtype-ok-r0`: `rew [100] in WASM-FIB-BS : Packtype-ok(CONCRETE-CONTEXT, CTORI8A0) .` -> valid after generic generated-predicate namespace fix
- `Storagetype-ok/val` / `storagetype-ok-val`: `rew [100] in WASM-FIB-BS : Storagetype-ok(CONCRETE-CONTEXT, CTORI32A0) .` -> valid
- `Storagetype-ok/pack` / `storagetype-ok-pack`: `rew [100] in WASM-FIB-BS : Storagetype-ok(CONCRETE-CONTEXT, CTORI8A0) .` -> valid after generic generated-predicate namespace fix

## Failed Concrete Tests
- `Resulttype-ok` / `resulttype-ok-r0`: `rew [100] in WASM-FIB-BS : Resulttype-ok(CONCRETE-CONTEXT, eps) .` -> stuck Resulttype-ok(CONCRETE-CONTEXT, eps); singleton CTORI32A0 succeeds; two-element i32 i32 also stuck
  - Cause: Strict one-rule lowering keeps the iterated premise as Valtype-ok(C, TS) => valid. For TS = eps or a multi-element list, no primary Valtype-ok rule validates the whole list; an executable fix would require iteration handling/witness machinery or a derived empty/list rule.
- `Instrtype-ok` / `instrtype-ok-r0`: `rew [100] in WASM-FIB-BS : Instrtype-ok(CONCRETE-CONTEXT, CTORARROWA3(eps, eps, eps)) .` -> stuck Instrtype-ok(CONCRETE-CONTEXT, CTORARROWA3(eps, eps, eps))
  - Cause: The empty x* premise is lowered to LCTS := index(value(LOCALS,C), eps), which reduces to stuck index(eps, eps), and both Resulttype-ok(C, eps) premises are stuck for the same strict iteration reason.

## Generic Translator Fix Applied
- Generated syntax/category predicates were renamed from $is-<sort> to $is-spectec-<sort> to avoid collision with source helper definitions such as $is_packtype.
- This is generic namespace hygiene for generated predicates; it does not add rules, helpers, derived empty cases, or Wasm judgement/constructor special cases.

## Strict C1 Limitations
- `Resulttype_ok` has source premise `(Valtype_ok: C |- t : OK)*`. The strict one-rule Maude lowering currently cannot execute the empty or multi-element cases because no derived iteration rule is allowed.
- `Instrtype_ok` combines two `Resulttype_ok` premises with an iterated local-index side condition. With `x* = eps`, the translated premise `index(value(LOCALS,C), eps)` is stuck; fixing execution would require faithful generic iteration/witness machinery, not a derived `instrtype-ok-r0-iter-empty0` rule.
- Other `structurally-suspicious` rows contain `*` or `?` premises and should be audited with targeted ground contexts in later batches.

## Structural Checks After Regeneration
- `grep -n "iter-empty\|opt-empty" output_bs.maude`: no result.
- `grep -nE "^[[:space:]]*(eq|ceq) .* = valid" output_bs.maude`: only `Expand`, `Num-ok`, and `Val-ok` footer/executable leftovers.
- Primary exact-RHS `=> valid` count remains 281.

## Warnings
- Loading `output_bs.maude` still emits existing Maude warnings about variables and multiple distinct sorts. This task did not address those broader warnings.

## Recommended Next Batch
Continue within validation by auditing `wasm-3.0/2.2-validation.subtyping.spectec`, especially the list/witness-heavy subtyping rules that depend on the `2.1` type judgements.
