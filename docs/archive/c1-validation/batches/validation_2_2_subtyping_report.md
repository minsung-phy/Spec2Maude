# Validation 2.2 Subtyping Strict C1 Report

## Scope

Source file: `wasm-3.0/2.2-validation.subtyping.spectec`

Strict policy: one SpecTec source relation rule maps to one primary Maude `rl`/`crl`; no derived `iter-empty` or `opt-empty` validation rules are allowed.

## Counts

- Source rules in 2.2: 50
- Structurally matched to generated primary `rl`/`crl`: 50
- Missing primary rules: 0
- Source rules still emitted as `eq`/`ceq ... = valid`: 0
- Derived `iter-empty` / `opt-empty` labels: 0

## Source Rules And Generated Labels

| Source rule | Generated label | Structural status | Test status |
|---|---|---|---|
| `Numtype-sub` | `numtype-sub-r0` | structurally-isomorphic | executable-success |
| `Vectype-sub` | `vectype-sub-r0` | structurally-isomorphic | executable-success |
| `Heaptype-sub/refl` | `heaptype-sub-refl` | structurally-isomorphic | not-ground-testable-yet |
| `Heaptype-sub/trans` | `heaptype-sub-trans` | structurally-suspicious | not-ground-testable-yet |
| `Heaptype-sub/eq-any` | `heaptype-sub-eq-any` | structurally-isomorphic | not-ground-testable-yet |
| `Heaptype-sub/i31-eq` | `heaptype-sub-i31-eq` | structurally-isomorphic | executable-success |
| `Heaptype-sub/struct-eq` | `heaptype-sub-struct-eq` | structurally-isomorphic | not-ground-testable-yet |
| `Heaptype-sub/array-eq` | `heaptype-sub-array-eq` | structurally-isomorphic | not-ground-testable-yet |
| `Heaptype-sub/struct` | `heaptype-sub-struct` | structurally-isomorphic | not-ground-testable-yet |
| `Heaptype-sub/array` | `heaptype-sub-array` | structurally-isomorphic | not-ground-testable-yet |
| `Heaptype-sub/func` | `heaptype-sub-func` | structurally-isomorphic | not-ground-testable-yet |
| `Heaptype-sub/def` | `heaptype-sub-def` | structurally-isomorphic | not-ground-testable-yet |
| `Heaptype-sub/typeidx-l` | `heaptype-sub-typeidx-l` | structurally-suspicious | not-ground-testable-yet |
| `Heaptype-sub/typeidx-r` | `heaptype-sub-typeidx-r` | structurally-suspicious | not-ground-testable-yet |
| `Heaptype-sub/rec` | `heaptype-sub-rec` | structurally-suspicious | not-ground-testable-yet |
| `Heaptype-sub/none` | `heaptype-sub-none` | structurally-isomorphic | not-ground-testable-yet |
| `Heaptype-sub/nofunc` | `heaptype-sub-nofunc` | structurally-isomorphic | not-ground-testable-yet |
| `Heaptype-sub/noexn` | `heaptype-sub-noexn` | structurally-isomorphic | not-ground-testable-yet |
| `Heaptype-sub/noextern` | `heaptype-sub-noextern` | structurally-isomorphic | not-ground-testable-yet |
| `Heaptype-sub/bot` | `heaptype-sub-bot` | structurally-isomorphic | not-ground-testable-yet |
| `Reftype-sub/nonnull` | `reftype-sub-nonnull` | structurally-isomorphic | executable-success |
| `Reftype-sub/null` | `reftype-sub-null` | structurally-isomorphic | not-ground-testable-yet |
| `Valtype-sub/num` | `valtype-sub-num` | structurally-isomorphic | executable-success |
| `Valtype-sub/vec` | `valtype-sub-vec` | structurally-isomorphic | not-ground-testable-yet |
| `Valtype-sub/ref` | `valtype-sub-ref` | structurally-isomorphic | not-ground-testable-yet |
| `Valtype-sub/bot` | `valtype-sub-bot` | structurally-isomorphic | not-ground-testable-yet |
| `Resulttype-sub` | `resulttype-sub-r0` | structurally-suspicious | executable-fail |
| `Instrtype-sub` | `instrtype-sub-r0` | structurally-suspicious | executable-fail |
| `Packtype-sub` | `packtype-sub-r0` | structurally-isomorphic | not-ground-testable-yet |
| `Storagetype-sub/val` | `storagetype-sub-val` | structurally-isomorphic | not-ground-testable-yet |
| `Storagetype-sub/pack` | `storagetype-sub-pack` | structurally-isomorphic | not-ground-testable-yet |
| `Fieldtype-sub/const` | `fieldtype-sub-const` | structurally-isomorphic | not-ground-testable-yet |
| `Fieldtype-sub/var` | `fieldtype-sub-w-var` | structurally-isomorphic | not-ground-testable-yet |
| `Comptype-sub/struct` | `comptype-sub-struct` | structurally-suspicious | not-ground-testable-yet |
| `Comptype-sub/array` | `comptype-sub-array` | structurally-isomorphic | not-ground-testable-yet |
| `Comptype-sub/func` | `comptype-sub-func` | structurally-suspicious | not-ground-testable-yet |
| `Deftype-sub/refl` | `deftype-sub-refl` | structurally-isomorphic | not-ground-testable-yet |
| `Deftype-sub/super` | `deftype-sub-super` | structurally-suspicious | not-ground-testable-yet |
| `Limits-sub/max` | `limits-sub-max` | structurally-suspicious | not-ground-testable-yet |
| `Limits-sub/eps` | `limits-sub-eps` | structurally-isomorphic | not-ground-testable-yet |
| `Tagtype-sub` | `tagtype-sub-r0` | structurally-isomorphic | not-ground-testable-yet |
| `Globaltype-sub/const` | `globaltype-sub-const` | structurally-isomorphic | not-ground-testable-yet |
| `Globaltype-sub/var` | `globaltype-sub-w-var` | structurally-isomorphic | not-ground-testable-yet |
| `Memtype-sub` | `memtype-sub-r0` | structurally-isomorphic | not-ground-testable-yet |
| `Tabletype-sub` | `tabletype-sub-r0` | structurally-isomorphic | not-ground-testable-yet |
| `Externtype-sub/tag` | `externtype-sub-tag` | structurally-isomorphic | not-ground-testable-yet |
| `Externtype-sub/global` | `externtype-sub-global` | structurally-isomorphic | not-ground-testable-yet |
| `Externtype-sub/mem` | `externtype-sub-mem` | structurally-isomorphic | not-ground-testable-yet |
| `Externtype-sub/table` | `externtype-sub-table` | structurally-isomorphic | not-ground-testable-yet |
| `Externtype-sub/func` | `externtype-sub-func` | structurally-isomorphic | not-ground-testable-yet |

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

- `Numtype-sub(C, CTORI32A0, CTORI32A0)` -> `valid`
- `Vectype-sub(C, CTORV128A0, CTORV128A0)` -> `valid`
- `Heaptype-sub(C, CTORI31A0, CTORWEQA0)` -> `valid`
- `Reftype-sub(C, CTORREFA2(eps, CTORI31A0), CTORREFA2(eps, CTORWEQA0))` -> `valid`
- `Valtype-sub(C, CTORI32A0, CTORI32A0)` -> `valid`
- `Resulttype-sub(C, CTORI32A0, CTORI32A0)` -> `valid`

### Failed / Stuck As Expected In Strict C1

- `Resulttype-sub(C, eps, eps)` stayed as `Resulttype-sub(C, eps, eps)`.

  Blocking premise: generated `resulttype-sub-r0` preserves the source iterated premise as `Valtype-sub(C, TS1, TS2) => valid`. For empty sequences, that becomes `Valtype-sub(C, eps, eps) => valid`; there is no primary source rule that validates the whole empty sequence. Adding `resulttype-sub-iter-empty` would restore executability, but it would be a derived validation rule and is forbidden in strict C1.

- `Instrtype-sub(C, CTORARROWA3(eps, eps, eps), CTORARROWA3(eps, eps, eps))` stayed as the original `Instrtype-sub(...)` term.

  Blocking premises observed independently:

  - `$setminus(localidx, eps, eps)` originally stayed stuck because generated DecD helper equations erased the syntax-parameter LHS argument to `eps`. This was fixed generically in the focused `$setminus` audit by translating all DecD LHS arguments with `translate_arg`; `$setminus(localidx, eps, eps)` now reduces to `eps`.
  - `index(value('LOCALS, C), eps)` reduces to stuck `index(eps, eps)` for the empty locals list.
  - Both `Resulttype-sub(C, eps, eps)` premises are stuck for the strict empty-iteration reason above.

No derived rule or helper shortcut was added for these failures.

## Structural Notes

Most direct leaf rules are structurally isomorphic and executable on ground leaf terms. Rules involving transitive/intermediate witnesses, optional premises, or `*` premises are structurally preserved but may not be executable by plain rewriting in strict C1. In this file, the most important examples are `Resulttype-sub`, `Instrtype-sub`, `Comptype-sub/struct`, `Comptype-sub/func`, `Heaptype-sub/trans`, `Deftype-sub/super`, and `Limits-sub/max`.

## Generator Changes

The initial 2.2 batch made no translator change. The follow-up focused `$setminus` audit fixed the generic DecD syntax/type-parameter LHS lowering bug: `TypA` helper arguments are now preserved on generated equation LHSs instead of being lowered to `eps`.

## Verification

- `grep -n "iter-empty\|opt-empty" output_bs.maude`: no results.
- Remaining `eq`/`ceq ... = valid`: footer/executable leftovers only: `Expand`, `Num-ok`, `Val-ok`.
- All 50 source rules from `2.2-validation.subtyping.spectec` have exactly one generated primary `crl`.

## Next Recommended Batch

Continue to `wasm-3.0/2.3-validation.modules.spectec`. Separately, audit empty locals indexing (`index(eps, eps)`) if `Instrtype-sub` execution needs to progress beyond the now-fixed `$setminus` premise.
