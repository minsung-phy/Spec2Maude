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

However, Maude does not combine the needed associative split with the conditional rewrite premise in some label/br suffix cases. The direct inner step succeeds, but the full context rule does not compose operationally in the strict single-rule form.

Label-related `step-from-step-pure-*` shortcuts remain as temporary executable debt. They are derived Step_pure-to-Step shortcuts and are not C1-final.

## 4. Concrete Store / Harness Lookup Limitation

Example:

- `Externaddr-ok/func` with `fib-store`.

The generated source rule needs:

```text
index(value('FUNCS, s), a)
```

to expose a function instance and project `TYPE`. The current concrete Fibonacci harness/store shape does not discharge that premise in the ground probe. This is a concrete store/harness lookup limitation, not a missing source-rule lowering.

## 5. Footer / Prelude / Genericity Debt

The footer still mixes:

- generic SpecTec prelude pieces;
- WebAssembly-specific helpers;
- executable scaffolding used by the current harness.

The historical source-rule footer duplicates for `Expand`, `Num-ok`, and
singleton `Val-ok` have been removed from the generator because primary
source-generated `crl`s already exist for those rules.

Remaining `eq` / `ceq ... = valid` leftovers are sequence-shaped `Val-ok`
list-lifting equations used by the current harness/prelude. They are not strict
source-target validation rules, and they are not C1-final. The footer and
prelude should be separated before non-Wasm SpecTec generalization, such as a
P4-oriented pass.

## 6. Model Checking Note

C1 strict is a structural and isomorphic baseline. It is not intended to be an analysis-optimized semantics.

Model checking, mode-aware validation solving, witness synthesis, and execution-oriented control infrastructure should be treated as C2-or-later work unless explicitly accepted into C1 after review.
