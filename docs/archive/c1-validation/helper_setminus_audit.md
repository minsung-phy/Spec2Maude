# `$setminus` DecD Helper Audit

## Source Definition

Source file: `wasm-3.0/0.3-aux.seq.spectec`

```spectec
def $setminus_(syntax X, X*, X*) : X*  hint(show %2\%3)
def $setminus1_(syntax X, X, X*) : X*

def $setminus_(syntax X, eps, w*) = eps
def $setminus_(syntax X, w_1 w'*, w*) = $setminus1_(X, w_1, w*) ++ $setminus_(X, w'*, w*)
def $setminus1_(syntax X, w, eps) = w
def $setminus1_(syntax X, w, w_1 w'*) = eps                     -- if w = w_1
def $setminus1_(syntax X, w, w_1 w'*) = $setminus1_(X, w, w'*)  -- otherwise
```

Intended meaning: `syntax X` is a syntax/category parameter. `$setminus_(X, xs, ys)` filters sequence `xs`, removing elements that occur in `ys`; `$setminus1_` keeps one element when it is not found in the second sequence. The first argument is not the sequence being filtered; it identifies the element syntax/category used by the polymorphic helper.

## Generated Maude Before The Fix

The generated helper equations had erased the syntax parameter on the LHS:

```maude
eq $setminus1 ( eps, SETMINUS10-W, eps ) = SETMINUS10-W .
ceq $setminus1 ( eps, SETMINUS11-W, ( SETMINUS11-W1 SETMINUS11-WSQ ) ) = eps
    if ( SETMINUS11-W == SETMINUS11-W1 ) .
eq $setminus1 ( eps, SETMINUS12-W, ( SETMINUS12-W1 SETMINUS12-WSQ ) ) =
  $setminus1 ( X, SETMINUS12-W, SETMINUS12-WSQ ) [owise] .

eq $setminus ( eps, eps, SETMINUS0-WS ) = eps .
eq $setminus ( eps, ( SETMINUS1-W1 SETMINUS1-WSQ ), SETMINUS1-WS ) =
  $setminus1 ( X, SETMINUS1-W1, SETMINUS1-WS ) $setminus ( X, SETMINUS1-WSQ, SETMINUS1-WS ) .
```

The `Instrtype-sub` premise calls `$setminus(localidx, x_2*, x_1*)`, so these equations could not match the empty case.

## Cause

This was a generic DecD translation bug. In `translate_decd`, LHS arguments were translated only when they were expression arguments (`ExpA`). Any non-expression argument, including type/syntax arguments (`TypA`), was replaced by `eps`. Calls and RHS expressions already used `translate_arg`, so they preserved syntax/type arguments such as `X` or `localidx`; only DecD equation LHSs were wrong.

Classification: generic DecD type/syntax-parameter lowering bug, not a strict C1 validation limitation and not a `$setminus`-specific issue.

## Generator Fix

Changed `translator_bs.ml` to translate DecD LHS arguments generically with `translate_arg`:

```ocaml
let lhs_ts : texpr list = List.map (fun a -> translate_arg a vm) lhs_args
```

This preserves `TypA`/syntax parameters on the LHS without special-casing `$setminus`, `localidx`, or `Instrtype-sub`.

## Generated Maude After The Fix

```maude
eq $setminus1 ( X, SETMINUS10-W, eps ) = SETMINUS10-W .
ceq $setminus1 ( X, SETMINUS11-W, ( SETMINUS11-W1 SETMINUS11-WSQ ) ) = eps
    if ( SETMINUS11-W == SETMINUS11-W1 ) .
eq $setminus1 ( X, SETMINUS12-W, ( SETMINUS12-W1 SETMINUS12-WSQ ) ) =
  $setminus1 ( X, SETMINUS12-W, SETMINUS12-WSQ ) [owise] .

eq $setminus ( X, eps, SETMINUS0-WS ) = eps .
eq $setminus ( X, ( SETMINUS1-W1 SETMINUS1-WSQ ), SETMINUS1-WS ) =
  $setminus1 ( X, SETMINUS1-W1, SETMINUS1-WS ) $setminus ( X, SETMINUS1-WSQ, SETMINUS1-WS ) .
```

## Direct Reductions

```maude
red in WASM-FIB-BS : localidx .
-- result V128: localidx

red in WASM-FIB-BS : $setminus(localidx, eps, eps) .
-- result Nonfuncs: eps

red in WASM-FIB-BS : $setminus1(localidx, 0, eps) .
-- result Zero: 0

red in WASM-FIB-BS : $setminus(localidx, 0, eps) .
-- result Zero: 0

red in WASM-FIB-BS : $setminus(localidx, 0, 0) .
-- result Nonfuncs: eps
```

`CTORLOCALIDXA0` is not a generated token in this output; Maude reports it as a bad token. The correct syntax/category token used by the generated `Instrtype-sub` premise is `localidx`.

## Validation Impact

`Instrtype-sub(C, CTORARROWA3(eps, eps, eps), CTORARROWA3(eps, eps, eps))` still does not rewrite to `valid`. After this fix, `$setminus` is no longer the blocker. The remaining blockers are:

- `index(value('LOCALS, C), eps)` reduces to stuck `index(eps, eps)` for the empty locals list.
- both `Resulttype-sub(C, eps, eps)` premises remain stuck because strict C1 preserves empty `*` premises and forbids derived `iter-empty` rules.

## Strict C1 Checks

- `grep -n "iter-empty\|opt-empty" output_bs.maude`: no results.
- Remaining `eq`/`ceq ... = valid`: footer/executable leftovers only: `Expand`, `Num-ok`, `Val-ok`.
- No derived validation rules were added.

## Execution Smokes

After regeneration:

- `$expanddt(value('TYPE, fib-funcinst))` -> `CTORFUNCARROWA2(CTORI32A0 CTORI32A0 CTORI32A0, CTORI32A0)`
- label/br suffix search -> exactly one solution
- `steps(fib-config(i32v(5)))` -> `(fib-store ; empty-frame) ; CTORCONSTA2(CTORI32A0, 5)`
