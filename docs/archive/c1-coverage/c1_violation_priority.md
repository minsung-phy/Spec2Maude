# C1 Isomorphism Violation Priority

Updated: 2026-05-20

This file prioritizes generated artifacts that are not direct SpecTec
source-to-Maude translations. It separates structural isomorphism issues from
plain executability limitations.

## P0: Must Resolve Or Ask Professor

### Label-Related `step-from-step-pure-*`

- Generated artifact: 20 `step-from-step-pure-*` rules at
  `output_bs.maude:8111-8301`.
- Classification: `NON_C1_FINAL_SCAFFOLD`.
- Why non-isomorphic: each rule is a derived Step_pure-to-Step shortcut, not a
  direct source `Step` rule.
- Needed for current execution: yes. Prior ablation preserved direct
  `step-pure(label(... br 0)) => eps`, but `step((Z ; label(... br 0)))` and
  the label/br suffix search failed, and Fibonacci execution got stuck.
- Removal attempted: yes; restored after no source-preserving generic fix was
  found.
- Recommended action: ask whether C1 may contain a generic operational bridge
  stronger than the strict source-shaped rules, or whether this belongs in C2.

## P1: Should Resolve Before C1 Final

### Footer / Prelude Separation

- Generated artifacts: mixed fixed header/footer support, including sequence
  substitution lifts, `CTORFRAMEA2` frame-record lowering, and Wasm-specific
  fixed atoms.
- Classification: mixed `GENERIC_SPECTEC_PRELUDE`,
  `WASM_SPECIFIC_SEMANTICS`, `EXECUTION_HARNESS`, and
  `NON_C1_FINAL_SCAFFOLD`.
- Why non-isomorphic: several pieces are not direct source constructs, or are
  source-derived only in part with extra executable footer equations.
- Needed for current execution: several are likely needed; others appear dead.
- Removal attempted: the sequence-shaped `Val-ok` list-lift, obvious dead
  helpers, finite type-iteration helpers, broad `$local` / `$with-local`
  footer duplicates, and the `$mk-frame` adapter were removed; accepted smokes
  still passed.
- Recommended action: ablate one family at a time. For frame records, the next
  step is to generate typed record constructors like `CTORFRAMEA2` from source
  record syntax generically rather than hardcoding the Wasm frame shape.

## P2: Cleanup / Genericity Improvement

### Resolved / Accepted: Sequence Substitution List Lifts

- Generated artifacts: `$subst-typeuse`, `$subst-valtype`, `$subst-subtype`
  sequence overloads/equations.
- Current classification: accepted C1 representation substrate for SpecTec
  star-map expressions such as `f(x)*`.
- Rationale: the element-level substitution definitions are source-derived, and
  the source equations explicitly map them over `*` sequences. Maude needs an
  operational list representation for that source meta-notation.
- Follow-up: generalize this pattern beyond footer strings, but do not treat it
  as a C1 isomorphism violation.

### Resolved: `$expanddt` Footer Shortcut

- Previous artifact: footer equation for `$expanddt`.
- Current state: removed from `translator_bs.ml` and regenerated
  `output_bs.maude`.
- Rationale: source-generated `$expanddt` definition from
  `1.2-syntax.types.spectec` already covers the behavior. Keeping the footer
  equation duplicated source logic.

### Resolved: Legacy Or Apparently Dead Helpers

- Generated artifacts: `$cfg-state`, `$cfg-instrs`, `needs-label-ctxt`,
  `is-trap`, stale `VALOK-*` variables, and finite type-iteration helpers
  `$rec-typevars`, `$def-typeuses`, `$idx-typeuses`.
- Classification: `DEAD_CAN_REMOVE`.
- Why non-isomorphic: no direct source provenance; current output appears to
  use them only in their declarations/equations.
- Needed for current execution: no.
- Removal attempted: yes.
- Current state: removed from `translator_bs.ml` and regenerated
  `output_bs.maude`; accepted execution smokes still pass.

### Generic Carrier Names

- Generated artifacts: `WasmTerminal`, `WasmTerminals`, `WasmType`,
  `WasmTypes`.
- Classification: `GENERIC_SPECTEC_PRELUDE`.
- Why non-isomorphic: acceptable generic carrier idea, but names are
  Wasm-specific and block professor-facing generic SpecTec claims.
- Needed for current execution: yes.
- Recommended action: parameterize or rename to neutral `SpecTec*` names in a
  separate genericity pass.

### Wasm-Specific Fixed Header Atoms And Index Sorts

- Generated artifacts: fixed index sorts and atoms such as `w-N`, `w-M`,
  `w-X`, `w-C`.
- Classification: `WASM_SPECIFIC_SEMANTICS`.
- Why non-isomorphic/genericity issue: they are not derived from the current
  source parse in a general way.
- Needed for current Wasm output: yes.
- Recommended action: generate from source syntax/category declarations or
  parameterize per input language.

### Resolved: Former Unknown Helper/Fallback Declarations

- Former artifact: `_shape-x_`.
- Current state: removed from `translator_bs.ml` and regenerated output.
- Rationale: direct source/output comparison showed that source
  `syntax shape = lanetype X dim` is already represented by generated
  `CTORXA2`; `_shape-x_` was a dead extra header declaration with no use.

- Former artifact: fallback `$f` overloads.
- Current classification: `SOURCE_DERIVED`.
- Rationale: `wasm-3.0/3.2-numerics.vector.spectec` contains higher-order
  `def $f_` parameters used by vector helper definitions. The generated `$f`
  declarations are representation support for those source parameters, not
  arbitrary helper debt.

## C2 Or Harness Layer

### Strict Validation Executability Limitations

- Examples: empty `*` premises, `Instrs-ok/seq` witness synthesis, sequence
  `Val-ok` probes.
- Classification: executability limitations, not missing or duplicated source
  rules.
- Recommended action: keep out of strict C1 unless professor approves a
  mode-aware solver or generic iteration encoding as part of C1.

### Step/ctxt-instrs Executability Limitation

- Example: strict source-shaped `Step/ctxt-instrs` does not operationally
  compose with the label/br inner step under Maude conditional rewriting.
- Classification: executability limitation plus P0 shortcut debt.
- Recommended action: either find a source-preserving generic context-closure
  encoding or move execution control infrastructure to C2.

### Benchmark Harness

- Generated/support artifacts: `fib-store`, `fib-config`, `fib-moduleinst`,
  `i32v`, and CTORI32A0-specific harness membership in `wasm-exec-bs.maude`.
- Classification: `BENCHMARK_HARNESS`.
- Recommended action: keep outside `translator_bs.ml` and outside the strict
  generated core.

## Next Fix Attempts

1. Professor decision on the 20 label-related shortcuts.
2. Design generic sequence-map lowering to replace hardcoded `$subst-*` list
   lifts.
3. P4/generalization pass for carrier names, fixed index sorts, and fixed
   Wasm atoms.
