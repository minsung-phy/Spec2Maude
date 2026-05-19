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

- Generated artifacts: mixed fixed header/footer support, including
  `$mk-frame`, sequence substitution lifts, and Wasm-specific fixed atoms.
- Classification: mixed `GENERIC_SPECTEC_PRELUDE`,
  `WASM_SPECIFIC_SEMANTICS`, `EXECUTION_HARNESS`, and
  `NON_C1_FINAL_SCAFFOLD`.
- Why non-isomorphic: several pieces are not direct source constructs, or are
  source-derived only in part with extra executable footer equations.
- Needed for current execution: several are likely needed; others appear dead.
- Removal attempted: the sequence-shaped `Val-ok` list-lift, obvious dead
  helpers, finite type-iteration helpers, and broad `$local` / `$with-local`
  footer duplicates were removed; accepted smokes still passed.
- Recommended action: ablate one family at a time. Defer `$mk-frame` until the
  execution harness boundary is explicitly designed.

### Sequence Substitution List Lifts

- Generated artifacts: `$subst-typeuse`, `$subst-valtype`, `$subst-subtype`
  sequence overloads/equations.
- Classification: `NON_C1_FINAL_SCAFFOLD`.
- Why non-isomorphic: source has element-level definitions; footer adds
  sequence lifting for source `f(x)*` map expressions.
- Needed for current execution: accepted Fibonacci smokes do not currently
  depend on them, but source substitution semantics does.
- Removal attempted: yes. The ablation kept accepted smokes passing, but
  `$subst-subtype` over a subtype sequence stopped reducing.
- Recommended action: replace with a generic source-preserving sequence-map
  lowering, or move hardcoded executable list lifting to C2.

### `$expanddt` Footer Shortcut

- Generated artifact: footer equation for `$expanddt`.
- Classification: `NON_C1_FINAL_SCAFFOLD`.
- Why non-isomorphic: shortcut overlaps source-generated Expand/unroll
  behavior without being a primary source rule.
- Needed for current execution: yes for current smokes and validation probes.
- Removal attempted: not in this pass.
- Recommended action: audit against source Expand definitions and decide
  whether the shortcut is generic definitional prelude or C2 support.

## P2: Cleanup / Genericity Improvement

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

### Unknown Helper/Fallback Declarations

- Generated artifacts: `_shape-x_` and fallback `$f` overloads.
- Classification: `UNKNOWN`.
- Why suspicious: source provenance was not established in this pass.
- Needed for current execution: unknown.
- Recommended action: use-site inventory before any removal.

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
