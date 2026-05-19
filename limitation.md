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

has no solution through the generic `crl [step-pure]` bridge. The suffix case
then fails for the same reason: `Step/ctxt-instrs` needs the inner premise
`step((Z ; label(... br 0))) => (Z ; eps)`, and that premise is not produced
operationally by the strict bridge.

Label-related `step-from-step-pure-*` shortcuts remain as temporary executable debt. They are derived Step_pure-to-Step shortcuts and are not C1-final.

## 4. Concrete Store / Harness Lookup Limitation

Example:

- `Externaddr-ok/func` with `fib-store`.

The generated source rule needs:

```text
index(value('FUNCS, s), a)
```

to expose a function instance and project `TYPE`. The current concrete Fibonacci harness/store shape does not discharge that premise in the ground probe. This is a concrete store/harness lookup limitation, not a missing source-rule lowering.

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

## 7. Model Checking Note

C1 strict is a structural and isomorphic baseline. It is not intended to be an analysis-optimized semantics.

Model checking, mode-aware validation solving, witness synthesis, and execution-oriented control infrastructure should be treated as C2-or-later work unless explicitly accepted into C1 after review.
