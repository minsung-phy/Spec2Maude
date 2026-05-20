# Record Sort / Binder Guard Audit

## Goal

We tried to remove generated binder guards such as:

```maude
if $is-spectec-context(C)
```

from source-unconditional rules such as:

```spectec
rule Instr_ok/nop:
  C |- NOP : eps -> eps
```

The desired C1 shape is an unconditional Maude rule whose left-hand-side
variable is natively sorted:

```maude
var C : Context .

rl [instr-ok-nop] :
  Instr-ok(C, CTORNOPA0, CTORARROWA3(eps, eps, eps))
  =>
  valid .
```

## Current Finding

This cannot be implemented safely by changing only record membership or
`dsl/pretype.maude`.

Current record literals are generic broad terms:

```maude
op {_} : RecordItems -> WasmTerminal .
```

`Context`, `Store`, and similar record categories are recognized by generated
membership axioms over the record shape and field guards. That is enough for
executable predicates such as `$is-spectec-context(C)`, but it is not enough for
a rewrite-rule LHS variable `C : Context` to match a broad record literal.

Direct experiment:

```maude
mod CONTEXT-LHS-TEST is
  inc WASM-FIB-BS .
  op Test-ok : WasmTerminals -> Judgement [ctor] .
  var C : Context .
  rl [test-context-lhs] : Test-ok(C) => valid .
endm

rew [10] in CONTEXT-LHS-TEST :
  Test-ok({item('TYPES, eps) ; item('RECS, eps) ; item('TAGS, eps) ;
   item('GLOBALS, eps) ; item('MEMS, eps) ; item('TABLES, eps) ;
   item('FUNCS, eps) ; item('DATAS, eps) ; item('ELEMS, eps) ;
   item('LOCALS, eps) ; item('LABELS, eps) ; item('RETURN, eps) ;
   item('REFS, eps)}) .
```

Result: the term remains stuck as `Test-ok(...)`. The sorted LHS variable does
not operationally match the current broad DSL record literal.

## Unsafe Shortcuts Rejected

Two tempting changes are not C1-safe:

1. `op {_} : RecordItems -> Context`

   This makes the LHS match, but every record literal becomes a `Context`,
   regardless of field names or field types. That is unsound.

2. Exact context record operator returning `Context`

   A fixed-field operator for the exact context shape can make matching work,
   but it creates a typed record parse distinct from the generic `{_}` record.
   Then generic `value(F, {RI})` projection and record update no longer reduce
   unless source-record-specific projection/update equations are generated.

   More importantly, the field arguments must have precise source sequence
   sorts such as `deftype*`, `localtype*`, `resulttype*`, etc. If they remain
   broad `WasmTerminals`, malformed records are accepted as `Context`.

   A follow-up generator experiment emitted exact source-shaped record
   operators such as:

   ```maude
   op {item`('TYPES`,_`) ; ... ; item`('REFS`,_`)}
     : SeqDeftype ... OptResulttype SeqFuncidx -> Context [ctor] .
   ```

   This was source-derived in intent, but unsafe in the current output because
   it coexisted with the generic DSL record operator:

   ```maude
   op {_} : RecordItems -> WasmTerminal .
   ```

   Concrete record terms then had multiple distinct parses. Relation calls such
   as `Numtype-ok({ ... }, CTORI32A0)` could be parsed at the wrong kind, and
   previously passing validation probes stopped rewriting. The experiment was
   reverted; the executable baseline was restored.

## Source-Derived Typed Record Layer Implemented

The generator now performs the first safe part of the redesign from SpecTec
source, not from `dsl/pretype.maude` hand-written record types:

1. It scans every source `StructT` declaration.
2. For each source record category, it generates a named typed record
   constructor such as:

   ```maude
   op RECContextA13 : WasmTerminals ... WasmTerminals -> Context [ctor] .
   op RECStoreA10 : WasmTerminals ... WasmTerminals -> Store [ctor] .
   op RECFrameA2 : WasmTerminals WasmTerminals -> Frame [ctor] .
   ```

3. It generates source-record projection, update, and typed merge equations:

   ```maude
   eq value('LOCALS, RECContextA13(..., LOCALS, ...)) = LOCALS .
   eq RECContextA13(...)[. 'LOCALS <- U] = RECContextA13(..., U, ...) .
   eq merge(RECContextA13(...), RECContextA13(...)) = RECContextA13(...) .
   ```

4. If a record field shape is unique in the source, the generator also emits a
   canonicalization equation from the generic DSL record form to the typed
   source-record constructor. If two source records share the same field shape
   (for example `tableinst` / `eleminst` or `structinst` / `arrayinst`), this
   generic canonicalization is intentionally skipped to avoid ambiguous
   rewriting. Their typed constructors and projection/update/merge equations
   are still generated.

This is an incremental source-derived representation layer. It replaces the
unsafe idea of hardcoding broad operators such as:

```maude
op context{_} : RecordItems -> Context .
```

The current layer is intentionally conservative: field arguments are still
carried as `WasmTerminals` so accepted execution remains stable. A later pass
can make those field arguments more precise once source sequence/category sorts
are represented uniformly.

## Record Binder Guard Removal Implemented

After adding the typed record layer, RelD lowering now preserves narrow Maude
sorts for source record categories generated from `StructT`. For example, a
source binder `C : context` becomes a Maude variable of sort `Context` in the
generated declaration block instead of being widened to `WasmTerminal` with a
predicate guard.

This removes binder-only record guards such as:

```maude
if $is-spectec-context(C)
```

from source-unconditional rules. Representative current output:

```maude
vars INSTR-OK-NOP0-C : Context .

rl [instr-ok-nop] :
  Instr-ok(INSTR-OK-NOP0-C, CTORNOPA0, CTORARROWA3(eps, eps, eps))
  =>
  valid .
```

The same pass removes generated `$is-spectec-context`,
`$is-spectec-store`, `$is-spectec-frame`, and
`$is-spectec-moduleinst` guards from the generated output.

The full regression still passes after this change.

## Non-Record Category Sorting Experiment

We also tested extending the same idea from records to ordinary syntax
categories such as `instr`, `expr`, `numtype`, and related constructor
categories. That experiment was not kept.

Two distinct cases must be separated:

1. Source constructors still have source-derived category evidence through the
   generated `mb` / `cmb` axioms. For example, `CONST ...` is recognized as an
   `instr` by source-derived membership, while its Maude operator remains a
   broad `WasmTerminal` constructor.
2. Replacing that with precise constructor result sorts or narrow LHS variables
   for sequence-decomposed categories is not currently safe. In particular,
   making instruction constructors directly return `Instr`, or preserving
   `Instr` on the LHS of `Instrs-ok/seq`, interacted badly with Maude AC
   sequence matching and the validation execution overlay. Representative
   probes such as `Expr-ok-const(C, CONST i32 0, i32)` could diverge or hit a
   Maude stack overflow.

So the current C1 baseline keeps non-record syntax constructors in the broad
`WasmTerminal` carrier plus source-derived membership/category predicates. This
is less pretty than fully sorted object syntax, but it is currently the
source-preserving executable choice. The record categories are different
because their generated `REC...` constructors are not AC sequence elements and
can safely be used as LHS sorts.

## Required Source-Preserving Design

To remove these guards safely, the generator needs a deeper typed syntax/record
representation:

1. Generate source-category sequence sorts or an equivalent representation for
   `T*`, `T?`, and record field types.
2. Generate source-shaped record constructors from `StructT` declarations, but
   do it with a representation that does not conflict with generic `{_}` parse
   forms. The current implementation uses named internal constructors such as
   `RECContextA13(...)`.
3. Generate projection/update equations for those source-shaped records.
4. Give nonzero source constructors precise result/argument sorts only after
   the sequence/membership interaction above is solved. The first direct
   experiment was rejected because it broke validation probes.
5. Continue reducing binder-only `$is-spectec-*` guards for non-record
   composite categories once their Maude representation is precise enough.

## Current C1 Status

Binder-only guards for source record categories have been removed by preserving
the source-derived record sort on the Maude LHS. Remaining binder-only
`$is-spectec-*` guards are for non-record/composite or parameterized categories
whose constructors are still carried through the broad `WasmTerminal` substrate.

The unsafe exact-record-operator experiment was not kept. The current generated
baseline instead has a source-derived `REC...` typed record layer, record-sorted
RelD variables, and accepted execution probes still pass.
