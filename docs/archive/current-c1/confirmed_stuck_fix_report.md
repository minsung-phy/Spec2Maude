# Confirmed Stuck Fix Report

Updated: 2026-05-20

This pass handled concrete stuck probes that had already been confirmed. The
policy was **generic C1-compatible repair first**: source-preserving generic
meta-lowering is allowed, but judgement-name hacks, constructor-specific
patches, benchmark adapters, old `iter-empty` / `opt-empty` validation-rule
copies, and manual `output_bs.maude` patches are not.

## Fixes Applied

### Generic Sequence Indexing

SpecTec source can use sequence indexing:

```text
xs[i*]
```

The generated Maude prelude now has a generic overload:

```maude
op index : WasmTerminals WasmTerminals -> WasmTerminals .
eq index(INDEX-TS, eps) = eps .
eq index(INDEX-TS, INDEX-I INDEX-IS) =
  index(INDEX-TS, INDEX-I) index(INDEX-TS, INDEX-IS) .
```

This is generic representation substrate for source meta-expressions. It is not
a judgement-specific executable shortcut.

### Generic Prefix-Constructor Star-Map Lowering

SpecTec source can use iterated constructor shapes such as:

```text
(SET t)*
```

Because the generated Maude sequence representation is flat, the empty case
cannot be matched by a literal pattern like `SET TS`. The translator now lowers
this pattern through generic prelude operators:

```maude
op $star-prefix : WasmTerminal WasmTerminals -> WasmTerminals .
op $star-unprefix : WasmTerminal WasmTerminals -> WasmTerminals .
```

Generated equality premises use `$star-unprefix(...)` plus an equality guard
against `$star-prefix(...)`. This is generic lowering for a source meta-shape,
not an `Instrtype-sub` special case.

### Generic Relation-Star Lowering

SpecTec source also has iterated relation premises:

```text
(J(...))* 
```

The translator now detects source `IterPr(RulePr(...))*` and emits a
source-driven `$iter-<relation>-<mask>` helper family. These helpers discharge
the empty case, fixed small concrete arities, and a recursive cons case for the
iterated source premise.

Important distinction:

- these helpers are generated from the source `P*` meta-construct;
- they are not hand-written footer equations;
- they do not hardcode names like `Resulttype-ok`, `Instrtype-ok`, or `Val-ok`;
- they are not the old per-source-rule `resulttype-ok-r0-iter-empty0` /
  `opt-empty` derived validation copies.

If the professor interprets strict C1 as "no helper relation even for source
meta-notation", this should be discussed as a C1/C2 boundary. Under the current
working interpretation, this is generic source-meta lowering.

### Generic Category Predicate Membership Fallback

Generated `$is-spectec-*` predicates now also recognize terms through their
Maude membership sort when the term is an opaque but typed harness constant.
This is generic predicate support, not a Wasm judgement-name patch.

### Generic LHS Projection Hoisting

Some source relation conclusions contain field projections, for example:

```text
Externaddr-ok(s, FUNC a, FUNC funcinst.TYPE)
```

The first strict rewrite lowering placed `value('TYPE, FUNCINST)` directly in
the generated rule LHS. Maude does not invert such projections from a concrete
target like `FUNC fib-type` to discover `FUNCINST`. The translator now
generically hoists `value('FIELD, VAR)` projections out of rewrite-rule LHS
patterns into ordinary equality conditions with a fresh LHS variable. This
preserves the source conclusion shape while making the rule operational for
concrete projected targets.

### Generic Expression-Star And Fixed-Repeat Lowering

SpecTec source can map a non-variable expression over a sequence and append a
fixed repetition:

```text
$ilt_(..., c_1, 0)* ++ (0)^(32-M)
```

The translator now lowers these source meta-expressions generically:

- `e*` where `e` is a source function call over one sequence argument becomes a
  generated `$map-...` helper;
- `e^n` where `n` is a non-variable count expression becomes `$repeat(e,n)`;
- generated map helpers recurse through `slice(seq, 1, len(seq)-1)` so they do
  not rely on Maude's broad associative split to make progress.

This is not a vector-specific patch for `$ivbitmaskop`; it is generic lowering
for source expression-star and fixed-repeat notation.

## Improved Probes

The following concrete probes now reduce:

```maude
red index(CTORI32A0 CTORI64A0, eps)
=> eps

red index(CTORI32A0 CTORI64A0, 0 1)
=> CTORI32A0 CTORI64A0

red index(value('LOCALS, concrete-context), eps)
=> eps

rew Resulttype-ok(concrete-context, eps)
=> valid

rew Resulttype-ok(concrete-context, CTORI32A0 CTORI32A0)
=> valid

rew Resulttype-sub(concrete-context, eps, eps)
=> valid

rew Instrtype-ok(concrete-context, CTORARROWA3(eps, eps, eps))
=> valid

rew Instrtype-sub(concrete-context,
  CTORARROWA3(eps, eps, eps),
  CTORARROWA3(eps, eps, eps))
=> valid

rew Instr-ok(concrete-context,
  CTORUNREACHABLEA0,
  CTORARROWA3(eps, eps, eps))
=> valid

rew Externaddr-ok(fib-store, CTORFUNCA1(0), CTORFUNCA1(fib-type))
=> valid

rew Instrs-ok(concrete-context, CTORNOPA0, arrow(eps, eps, eps))
=> valid

rew Expr-ok(concrete-context, CTORNOPA0, eps)
=> valid

red $map-Silt-a4-s2(32, CTORSA0, 1 0 2 0, 0)
=> 0 0 0 0

red $repeat(0, 4)
=> 0 0 0 0

red $ivbitmaskop(CTORXA2(CTORI32A0, 4), 0)
=> $ivbitmaskop(CTORXA2(CTORI32A0, 4), 0)

```

`$invoke` is a rewrite rule, not a pure equation:

```maude
red $invoke(...)
```

only equation-normalizes the arguments and remains `$invoke(...)`, while:

```maude
rew $invoke(...)
```

rewrites to a concrete `Config`.

## Remaining Confirmed Stuck Items

These were intentionally not forced with judgement-specific shortcuts:

- Direct sequence-shaped `Val-ok(fib-store, eps, eps)` and multi-value
  `Val-ok(...)` probes remain stuck. The source relation is singleton
  `Val-ok`; source `Val-ok*` premises are now handled through generated
  `$iter-val-ok-kss`, so the old footer list-lift should not be reintroduced.
- `steps(fib-config-invoke(i32v(5)))` now gets past `$invoke`, but still stops
  at the outer invoke frame/label/block shape. `$invoke` itself rewrites to a
  concrete `Config`, and the same outer frame shape executes to `5` if the
  caller frame is the named harness `empty-frame`. The source-shaped `$invoke`
  frame uses a literal `{MODULE {}}` module-instance record, and Maude does not
  compose the recursive `steps-trans` / `Step/ctxt-frame` conditional premises
  through that record-shaped caller frame.

Rejected experiment: orienting `Steps/trans` as
`steps(C) => steps(C') if step(C) => C'` made the closure more incremental, but
it allowed the unconditional `Steps/refl` source rule to fire too early at
  intermediate configurations and broke `steps(fib-config(i32v(5)))`. That
  experiment was reverted.
- `$ivbitmaskop` / `$vbitmaskop` no longer stack-overflow, but the direct probe
  still remains symbolic. The generated rule now preserves
  `$ilt(...)* ++ (0)^(32-M)` via generic `$map-*` and `$repeat`, but full
  execution still needs operational support for source inverse hints such as
  `$ibits` / `$inv_ibits` and for vector builtins such as `$lanes`.

## Validation Execution Overlay

The simplest `Instrs-ok/seq` witness probe now executes:

```maude
rew Instrs-ok(C0, CTORNOPA0, CTORARROWA3(eps, eps, eps))
=> valid

rew Expr-ok(C0, CTORNOPA0, eps)
=> valid
```

This was not fixed by adding judgement-specific rules. The translator now emits
a generic, source-driven execution overlay:

- `$infer-<relation>-argN` functions infer one missing relation argument from
  the other bound arguments using the source relation rules;
- `-exec-tail-emptyN` variants instantiate empty tails in source sequence
  patterns, so concrete singleton cases can be tried before broad associative
  matching.

An earlier `$exec-<relation>-argN` bridge layer was removed again because it
duplicated source relations and introduced recursive stack overflows. The
remaining overlay is limited to helper-side witness inference used by generated
conditions.

Remaining validation execution gap:

```maude
rew Instrs-ok(C0, CTORCONSTA2(CTORI32A0, 0),
  CTORARROWA3(eps, eps, CTORI32A0))
=> stack overflow

rew Expr-ok-const(C0, CTORCONSTA2(CTORI32A0, 0), CTORI32A0)
=> stack overflow
```

The current hypothesis is that value-producing non-empty instruction sequences
still need a mode-aware/principal-type validation solver. Adding
judgement-specific shortcuts remains out of scope for strict C1.

This overlay is useful executable scaffolding, but it is not itself a SpecTec
source rule. It should be reviewed as a C1/C2 boundary decision. The strict
primary source rules are still generated and source-shaped; the overlay is
extra execution machinery.

## Warning Classification

The regression script now records Maude warning classes. The current load still
has used-before-bound warnings, including validation rules with witness-style
variables. The new execution overlay improves focused concrete probes, but it
does not erase every source-level mode issue. Remaining warnings should be
handled one family at a time rather than by deleting or weakening premises.

## Invariants

After regeneration:

- no `eq` / `ceq ... = valid` rows remain;
- no old `iter-empty` or `opt-empty` labels exist;
- label-related `step-from-step-pure-*` count remains 20;
- the translator still has no forbidden benchmark or validation-judgement
  hardcoding according to the project grep.

## Execution Smokes

The accepted smoke tests still pass:

- `$expanddt(value('TYPE, fib-funcinst))`;
- label/br suffix search with `CTORFRAMEA2(...)`;
- br_if suffix search;
- nop suffix search;
- `steps(fib-config(i32v(5)))`.
