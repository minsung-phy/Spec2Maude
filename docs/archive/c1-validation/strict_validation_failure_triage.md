# Strict Validation Failure Triage

Updated: 2026-05-20

This note audits strict validation rules that are structurally translated to
primary Maude `rl` / `crl` rules but do not execute by plain rewriting in the
current C1 baseline.

No generator change was applied in this pass. No derived validation rules were
introduced.

In commands below, `C0` abbreviates the concrete empty validation context used
throughout the previous validation batches:

```maude
{item('TYPES, eps) ; item('RECS, eps) ; item('TAGS, eps) ;
 item('GLOBALS, eps) ; item('MEMS, eps) ; item('TABLES, eps) ;
 item('FUNCS, eps) ; item('DATAS, eps) ; item('ELEMS, eps) ;
 item('LOCALS, eps) ; item('LABELS, eps) ; item('RETURN, eps) ;
 item('REFS, eps)}
```

## Invariants Checked

```text
grep -nE "^[[:space:]]*(eq|ceq) .* = valid" output_bs.maude
```

Result: no output.

```text
grep -n "iter-empty\|opt-empty" output_bs.maude
```

Result: no output.

```text
grep -n "step-from-step-pure-" output_bs.maude | wc -l
```

Result: `20`.

```text
grep -n "Func-ok\|Instrs-ok\|Module-ok\|Externaddr-ok\|fib\|CTORI32A0" translator_bs.ml
```

Result: no output.

## 1. Empty `*` Premises

Representative stuck probes:

```maude
rew [100] in WASM-FIB-BS : Resulttype-ok(C0, eps) .
rew [100] in WASM-FIB-BS : Resulttype-sub(C0, eps, eps) .
```

Both remain as unreduced `Judgement` terms.

Representative successful nonempty probes:

```maude
rew [100] in WASM-FIB-BS : Resulttype-ok(C0, CTORI32A0) .
rew [100] in WASM-FIB-BS : Resulttype-sub(C0, CTORI32A0, CTORI32A0) .
```

Both rewrite to `valid`.

Source rules:

- `wasm-3.0/2.1-validation.types.spectec:52` `Resulttype_ok`
- `wasm-3.0/2.2-validation.subtyping.spectec:119` `Resulttype_sub`

Generated primary rules:

- `output_bs.maude:4904` `[resulttype-ok-r0]`
- `output_bs.maude:5152` `[resulttype-sub-r0]`

Blocking premises:

```maude
Valtype-ok(C, TS) => valid
Valtype-sub(C, TS1, TS2) => valid
```

These are generated from source iterated premises:

```text
(Valtype_ok: C |- t : OK)*
(Valtype_sub: C |- t_1 <: t_2)*
```

For `eps`, the source premise is vacuously true. In the current strict encoding,
it becomes a single relation premise over `eps`, and there is intentionally no
derived `iter-empty` rule to discharge it.

Classification: `STRICT_EMPTY_STAR_LIMITATION`.

Source-preserving repair assessment: ordinary Maude rewrite conditions are
existential checks over concrete terms. They do not provide a universal
"for every element of this sequence" condition, nor a built-in vacuous empty
case for source meta-iteration. A single condition like
`Valtype-ok(C, T) => valid` would be existential and wrong; a condition like
`Valtype-ok(C, TS) => valid` treats the sequence as one relation argument and
does not express the source iteration. Executable handling needs either derived
empty/cons rules or a generic iteration solver, both outside strict C1.

## 2. `Instrtype-ok` And `Instrtype-sub`

Representative stuck probes:

```maude
rew [100] in WASM-FIB-BS :
  Instrtype-ok(C0, CTORARROWA3(eps, eps, eps)) .

rew [100] in WASM-FIB-BS :
  Instrtype-sub(C0, CTORARROWA3(eps, eps, eps),
                    CTORARROWA3(eps, eps, eps)) .
```

Both remain as unreduced `Judgement` terms.

Source rules:

- `wasm-3.0/2.1-validation.types.spectec:56` `Instrtype_ok`
- `wasm-3.0/2.2-validation.subtyping.spectec:123` `Instrtype_sub`

Generated primary rules:

- `output_bs.maude:5188` `[instrtype-ok-r0]`
- `output_bs.maude:5299` `[instrtype-sub-r0]`

Blocking premises:

```maude
LCTS := index(value('LOCALS, C), XS)
CTORSETA0 TS := index(value('LOCALS, C), XS)
Resulttype-ok(C, eps) => valid
Resulttype-sub(C, eps, eps) => valid
```

Direct helper probes:

```maude
red in WASM-FIB-BS : value('LOCALS, C0) .
-- result: eps

red in WASM-FIB-BS : index(eps, eps) .
-- result: index(eps, eps)

red in WASM-FIB-BS : $setminus(localidx, eps, eps) .
-- result: eps
```

The `$setminus` DecD translation is no longer the blocker. The remaining
sequence-index shape comes from source iterated side conditions such as:

```text
(if C.LOCALS[x] = lct)*
(if C.LOCALS[x] = SET t)*
```

The generic prelude currently defines only singleton lookup:

```maude
op index : WasmTerminals Nat -> WasmTerminal .
eq index(T TS, 0) = T .
eq index(T TS, s(N')) = index(TS, N') .
```

There is no source-derived sequence lookup `index(L, eps) = eps`.

Classification: `STRICT_EMPTY_STAR_LIMITATION` plus
`GENERIC_SPECTEC_META_LOWERING_ISSUE` for iterated side-condition execution.

Source-preserving repair assessment: adding `index(L, eps) = eps` and recursive
sequence-index equations would be a generic list-lift for SpecTec meta-iteration,
not a direct source rule. It may be a reasonable C2 execution prelude, but it
would hide the strict C1 limitation unless accepted explicitly.

## 3. `Instr-ok/unreachable`

Representative stuck probe:

```maude
rew [100] in WASM-FIB-BS :
  Instr-ok(C0, CTORUNREACHABLEA0, CTORARROWA3(eps, eps, eps)) .
```

Result: unreduced `Instr-ok(...)`.

Source rule:

- `wasm-3.0/2.3-validation.instructions.spectec:21`
  `Instr_ok/unreachable`

Generated primary rule:

- `output_bs.maude:5455` `[instr-ok-unreachable]`

Blocking premise:

```maude
Instrtype-ok(C, CTORARROWA3(eps, eps, eps)) => valid
```

Classification: inherits `STRICT_EMPTY_STAR_LIMITATION` and the iterated
locals side-condition issue from `Instrtype-ok`.

## 4. `Instrs-ok/seq`

Representative stuck probe:

```maude
rew [1000] in WASM-FIB-BS :
  Instrs-ok(C0, CTORNOPA0, CTORARROWA3(eps, eps, eps)) .
```

Result: unreduced `Instrs-ok(...)`.

Control probes:

```maude
rew [100] in WASM-FIB-BS :
  Instr-ok(C0, CTORNOPA0, CTORARROWA3(eps, eps, eps)) .
-- result: valid

rew [100] in WASM-FIB-BS :
  Instrs-ok(C0, eps, CTORARROWA3(eps, eps, eps)) .
-- result: valid
```

Source rule:

- `wasm-3.0/2.3-validation.instructions.spectec:617`
  `Instrs_ok/seq`

Generated primary rule:

- `output_bs.maude:6007` `[instrs-ok-seq]`

Blocking premises:

```maude
INITS TS := index(value('LOCALS, C), XS1)
Instr-ok(C, instr1, CTORARROWA3(TS1, XS1, TS2)) => valid
Instrs-ok($with-locals(...), instrs2, CTORARROWA3(TS2, XS2, TS3)) => valid
```

Two temporary probe relations were tested:

- `probe-no-index`: source-order `Instr-ok` premise followed by recursive
  `Instrs-ok`, with the locals-index premise omitted.
- `probe-with-index`: same, but with the locals-index premise after `Instr-ok`.

Both remained stuck on the `NOP` example. Maude also warned that `TS2` was used
before it was bound in the probe rules. This shows that even without the
locals-index premise, the current `Judgement => valid` rewrite condition does
not synthesize the intermediate `TS2` witness from the `Instr-ok` premise.

Classification: `WITNESS_SYNTHESIS_LIMITATION`, with an additional
`GENERIC_SPECTEC_META_LOWERING_ISSUE` for the iterated locals side condition.

Source-preserving repair assessment: premise reordering to source order is
more faithful than the current scheduling, but it is not enough for execution.
Maude rewriting of conditional rules is not doing the needed proof search over
the output-bearing relation premise. A mode-aware solver, narrowing/search, or
explicit derived rule family would be needed. That belongs in C2 unless approved
as C1 infrastructure.

## 5. Expr / Global Dependency

Representative stuck probes:

```maude
rew [100] in WASM-FIB-BS :
  Expr-ok(C0, CTORCONSTA2(CTORI32A0, 5), CTORI32A0) .

rew [100] in WASM-FIB-BS :
  Expr-ok-const(C0, CTORCONSTA2(CTORI32A0, 5), CTORI32A0) .

rew [100] in WASM-FIB-BS :
  Global-ok(C0, CTORGLOBALA2(CTORMUTA0 CTORI32A0,
                             CTORCONSTA2(CTORI32A0, 5)),
                CTORMUTA0 CTORI32A0) .
```

All remain unreduced.

Successful dependencies:

```maude
rew [100] in WASM-FIB-BS :
  Instr-ok(C0, CTORCONSTA2(CTORI32A0, 5),
           CTORARROWA3(eps, eps, CTORI32A0)) .
-- result: valid

rew [100] in WASM-FIB-BS :
  Expr-const(C0, CTORCONSTA2(CTORI32A0, 5)) .
-- result: valid

rew [100] in WASM-FIB-BS :
  Globaltype-ok(C0, CTORMUTA0 CTORI32A0) .
-- result: valid
```

Source rules:

- `wasm-3.0/2.3-validation.instructions.spectec:638` `Expr_ok`
- `wasm-3.0/2.3-validation.instructions.spectec:699` `Expr_ok_const`
- `wasm-3.0/2.4-validation.modules.spectec:30` `Global_ok`

Generated primary rules:

- `output_bs.maude:6026` `[expr-ok-r0]`
- `output_bs.maude:6128` `[expr-ok-const-r0]`
- `output_bs.maude:6152` `[global-ok-r0]`

Blocking premise:

```maude
Instrs-ok(C, instrs, CTORARROWA3(eps, eps, TS)) => valid
```

Classification: transitive `WITNESS_SYNTHESIS_LIMITATION` through
`Instrs-ok/seq`.

## 6. Externaddr-ok / Function Harness Lookup

Representative stuck probe:

```maude
rew [100] in WASM-FIB-BS :
  Externaddr-ok(fib-store, CTORFUNCA1(0),
                CTORFUNCA1(value('TYPE, fib-funcinst))) .
```

Result: unreduced `Externaddr-ok(...)`.

Source rule:

- `wasm-3.0/4.1-execution.values.spectec:104`
  `Externaddr_ok/func`

Generated primary rule:

- `output_bs.maude:8027` `[externaddr-ok-func]`

The store lookup itself works:

```maude
red in WASM-FIB-BS : value('FUNCS, fib-store) .
-- result: fib-funcinst

red in WASM-FIB-BS : index(value('FUNCS, fib-store), 0) .
-- result: fib-funcinst

rew [100] in WASM-FIB-BS :
  index(value('FUNCS, fib-store), 0) == fib-funcinst .
-- result: true
```

The blocking premise is the generated source-sort guard:

```maude
$is-spectec-funcinst(fib-funcinst)
```

which does not reduce. The generated predicate recognizes the source record
shape:

```maude
{item('TYPE, F-TYPE) ; item('MODULE, F-MODULE) ; item('CODE, F-CODE)}
```

but the Fibonacci harness declares `fib-funcinst` as an opaque `Funcinst`
constant with field-projection equations.

Classification: `HARNESS_LOOKUP_LIMITATION`.

Source-preserving repair assessment: representing the harness function instance
with the generated source record shape would likely discharge this guard. That
is a harness-shape cleanup, not a validation translator bug and not part of this
task.

## 7. Val-ok Sequence Probes

Representative stuck probes:

```maude
rew [100] in WASM-FIB-BS : Val-ok(fib-store, eps, eps) .
rew [100] in WASM-FIB-BS :
  Val-ok(fib-store,
    CTORCONSTA2(CTORI32A0, 5) CTORCONSTA2(CTORI32A0, 0),
    CTORI32A0 CTORI32A0) .
```

Both remain unreduced.

Successful singleton probe:

```maude
rew [100] in WASM-FIB-BS :
  Val-ok(fib-store, CTORCONSTA2(CTORI32A0, 5), CTORI32A0) .
-- result: valid
```

Source rules:

- `wasm-3.0/4.1-execution.values.spectec:71` `Val_ok/num`
- `wasm-3.0/4.1-execution.values.spectec:75` `Val_ok/vec`
- `wasm-3.0/4.1-execution.values.spectec:79` `Val_ok/ref`

Generated primary rules:

- `output_bs.maude:7989` `[val-ok-num]`
- `output_bs.maude:7994` `[val-ok-vec]`
- `output_bs.maude:7999` `[val-ok-ref]`

There is no source `Val_ok` rule over `val*` / `valtype*`. The old
sequence-shaped footer equations were list-lifting scaffolding and have been
removed from strict C1.

Classification: `PRELUDE_HELPER_LIMITATION`.

Source-preserving repair assessment: do not reintroduce sequence-shaped
`Val-ok` in C1 unless a generic, professor-approved validation solver handles
source meta-iteration separately from source relation rules.

## Execution Smokes

The existing accepted execution smokes still pass:

- `$expanddt(value('TYPE, fib-funcinst))` reduces to
  `CTORFUNCARROWA2(CTORI32A0 CTORI32A0 CTORI32A0, CTORI32A0)`;
- label/br + suffix search has exactly one `Config` solution;
- br_if + suffix search has exactly one `Config` solution;
- nop + suffix search has exactly one `Config` solution;
- `rew [10000] steps(fib-config(i32v(5)))` ends with
  `CTORCONSTA2(CTORI32A0, 5)`.

Maude still emits existing parse, advisory, and used-before-bound warnings while
loading. No new warning class was introduced by this audit.

## Conclusion

No clear generic C1-isomorphic translator bug was found in this pass.

Remaining validation executability failures require one of:

- derived empty/cons handling for source meta-iteration;
- a mode-aware validation proof search / witness synthesis layer;
- generic sequence-index list lifting for iterated side conditions;
- harness representation cleanup for opaque store values.

Those are best treated as professor-review questions or C2 execution-layer work,
not silent strict-C1 generator patches.
