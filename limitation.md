# C1 Strict Limitations

Updated: 2026-05-20

This note records known limitations of the strict C1 baseline. These are not missing source-rule translations. They are places where the relation-preserving encoding is structurally faithful but not fully executable by plain Maude rewriting, or where remaining footer/harness scaffolding needs later separation.

## 1. Empty `*` Premise Limitation

Examples:

- `Resulttype-ok(C, eps)`;
- `Resulttype-sub(C, eps, eps)`;
- `Instrtype-ok(C, arrow(eps, eps, eps))`;
- `Instrtype-sub(C, arrow(eps, eps, eps), arrow(eps, eps, eps))`.

Strict C1 preserves the source iterated premise structurally. Without derived `iter-empty` rules, plain Maude rewriting does not discharge empty-list cases. Reintroducing `iter-empty` / `opt-empty` rules would improve executability, but those rules are derived executable scaffolding and are not allowed in strict C1.

## 2. `Instrs-ok/seq` Witness Synthesis Limitation

Example:

- `Instrs-ok(C, CTORNOPA0, arrow(eps, eps, eps))`.

The source rule has an intermediate witness variable, such as `TS2`, that is produced by one premise and consumed by another:

```text
Instr-ok(C, instr1, arrow(TS1, XS1, TS2)) => valid
Instrs-ok(C', instrs2, arrow(TS2, XS2, TS3)) => valid
```

The current `Judgement => valid` encoding checks relation facts but does not synthesize such intermediate witnesses. This is a mode / witness-search limitation, not a missing primary rule.

A focused probe also showed that the generated local-initialization premise:

```text
index(value('LOCALS, C), eps)
```

does not reduce in the current generic prelude. The prelude only provides
single-index lookup `index(WasmTerminals, Nat)`. A sequence-index/list-lift
equation such as `index(L, eps) = eps` would be executable support for iterated
SpecTec side conditions, not a direct source validation rule.

## 3. `Step/ctxt-instrs` Executability Limitation

The strict single `Step/ctxt-instrs` rule is structurally close to the original SpecTec rule. It should cover cases such as:

```text
label(... br 0) local.get 1
```

with the split:

```text
redex = label(... br 0)
suffix = local.get 1
```

However, Maude does not combine the needed generated bridge / conditional
rewrite premises in some label-related cases. A focused ablation showed the
sharper obstruction:

```text
step-pure(label(... br 0)) => eps
```

succeeds, but with the derived label shortcuts removed:

```text
step((Z ; label(... br 0)))
```

has no solution through the generic `crl [step-pure]` bridge. Additional probes
showed:

- the bridge LHS can match the label configuration;
- the exact premise `step-pure(label(... br 0)) => eps` succeeds;
- the variable premise `step-pure(INSTRS) => INSTRSQ` fails for this label/br
  case when `INSTRSQ` is sorted as `WasmTerminals`;
- broadening the result variable to the wrapper sort `StepPureConf` is
  operationally unsound for C1 because the rewrite condition can be satisfied
  by the zero-step unreduced term `step-pure(...)`;
- Maude 3.5.1 does not accept a non-reflexive `=>!` rewrite condition form.

The suffix case then fails for the same reason: `Step/ctxt-instrs` needs the
inner premise `step((Z ; label(... br 0))) => (Z ; eps)`, and that premise is
not produced operationally by the strict bridge.

Label-related `step-from-step-pure-*` shortcuts remain as temporary executable debt. They are derived Step_pure-to-Step shortcuts and are not C1-final.

## 4. Concrete Store / Harness Lookup Limitation

Example:

- `Externaddr-ok/func` with `fib-store`.

The generated source rule needs:

```text
index(value('FUNCS, s), a)
```

to expose a function instance and project `TYPE`. In the current Fibonacci
harness, the lookup itself succeeds:

```text
index(value('FUNCS, fib-store), 0) = fib-funcinst
```

but `fib-funcinst` is an opaque harness constant with field-projection
equations. The generated structural predicate `$is-spectec-funcinst` recognizes
the source record shape for function instances and does not reduce on that
opaque constant. This is a concrete harness representation limitation, not a
missing source-rule lowering.

## 5. Sequence `Val-ok` Executability Limitation

Examples:

- `Val-ok(fib-store, eps, eps)`;
- `Val-ok(fib-store, CTORCONSTA2(CTORI32A0, 5) CTORCONSTA2(CTORI32A0, 0), CTORI32A0 CTORI32A0)`.

Strict C1 now keeps only the source-generated singleton `Val-ok` rules, such as
`Val-ok/num` and `Val-ok/vec`. The previous footer equations that lifted
`Val-ok` pointwise over `val*` / `valtype*` were executable scaffolding, not
SpecTec source-rule targets, and have been removed from the strict core.

The singleton probe:

```text
Val-ok(fib-store, CTORCONSTA2(CTORI32A0, 5), CTORI32A0)
```

still rewrites to `valid`. Empty and multi-value sequence probes remain stuck
unless a later C2-style execution layer or principled mode-aware validation
solver provides list lifting.

## 6. Footer / Prelude / Genericity Debt

The footer still mixes:

- generic SpecTec prelude pieces;
- WebAssembly-specific helpers;
- executable scaffolding used by the current harness.

The historical source-rule footer duplicates for `Expand`, `Num-ok`, and
singleton `Val-ok` have been removed from the generator because primary
source-generated `crl`s already exist for those rules.

The sequence-shaped `Val-ok` list-lifting equations have also been removed from
the strict core after confirming that accepted Fibonacci execution smokes do not
depend on them. The current strict output has no `eq` / `ceq ... = valid`
leftovers.

The footer and prelude still contain other helper infrastructure and should be
separated before non-Wasm SpecTec generalization, such as a P4-oriented pass.

Current focused helper classifications:

- `$subst-typeuse`, `$subst-valtype`, and `$subst-subtype` are source-derived at
  the element-definition level, but the remaining footer sequence-lift overloads
  are source-absent scaffolding for SpecTec star-map expressions such as
  `$subst_valtype(t, tv*, tu*)*`. A temporary ablation kept Fibonacci execution
  smokes passing but regressed source substitution over subtype sequences, so
  the lifts remain until a generic source-preserving sequence-map lowering
  exists.
- `is-val` / `all-vals` are not SpecTec source definitions. They operationalize
  `val*` prefixes in translated execution rules such as `Step/ctxt-instrs`.
  They are not removable without replacing them by a generic category-sequence
  predicate/lowering.
- `$mk-frame` is not a SpecTec source def. It represents the source frame record
  shape with a typed Maude constructor and projection/update equations. It is
  still required by the current execution representation and accepted Fibonacci
  smokes.
- `$rec-typevars`, `$def-typeuses`, and `$idx-typeuses` were source-absent and
  unused finite type-iteration helpers. They have been removed from the active
  generator and regenerated output.

## 7. Model Checking Note

C1 strict is a structural and isomorphic baseline. It is not intended to be an analysis-optimized semantics.

Model checking, mode-aware validation solving, witness synthesis, and execution-oriented control infrastructure should be treated as C2-or-later work unless explicitly accepted into C1 after review.
