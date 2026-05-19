# Non-Isomorphic And Suspicious Generated Items

Updated: 2026-05-20

This file prioritizes generated output that is structurally covered but not strict C1-final, or that deserves label/isomorphism cleanup. These are not missing source rules unless explicitly marked.

## P0: Label-Related `step-from-step-pure-*` Debt

- Count: 20
- Classification: non-C1-final executable scaffolding.
- Current state: label-related shortcuts remain; non-label shortcuts are absent.
- Reason retained: strict `Step_pure` primary rules and strict `Step/ctxt-instrs`
  are source-shaped, but Maude does not operationally compose the generated
  generic `step-pure` bridge for label-shaped instruction terms. In the
  controlled ablation where all 20 remaining label shortcuts were removed,
  `step-pure(label(... br 0))` rewrote to `eps`, but
  `step((Z ; label(... br 0)))` had no solution. Consequently,
  `Step/ctxt-instrs` also could not prove the inner premise needed for
  `label(... br 0) local.get 1`.

Representative labels:

- line 8111: `step-from-step-pure-label-vals`
- line 8116: `step-from-step-pure-label-vals-ctx-suffix`
- line 8121: `step-from-step-pure-label-vals-ctx-prefix`
- line 8126: `step-from-step-pure-label-vals-ctx-prefix-suffix`
- line 8136: `step-from-step-pure-br-label-zero`
- line 8141: `step-from-step-pure-br-label-zero-ctx-suffix`
- line 8146: `step-from-step-pure-br-label-zero-ctx-prefix`
- line 8151: `step-from-step-pure-br-label-zero-ctx-prefix-suffix`
- line 8161: `step-from-step-pure-br-label-succ`
- line 8166: `step-from-step-pure-br-label-succ-ctx-suffix`
- line 8171: `step-from-step-pure-br-label-succ-ctx-prefix`
- line 8176: `step-from-step-pure-br-label-succ-ctx-prefix-suffix`
- line 8249: `step-from-step-pure-return-label`
- line 8254: `step-from-step-pure-return-label-ctx-suffix`
- line 8259: `step-from-step-pure-return-label-ctx-prefix`
- line 8264: `step-from-step-pure-return-label-ctx-prefix-suffix`
- line 8288: `step-from-step-pure-trap-label`
- line 8292: `step-from-step-pure-trap-label-ctx-suffix`
- line 8296: `step-from-step-pure-trap-label-ctx-prefix`
- line 8301: `step-from-step-pure-trap-label-ctx-prefix-suffix`

Non-label `step-from-step-pure-*` shortcuts found: 0

Latest ablation result:

- Temporarily removing only these 20 label-related shortcuts preserved primary
  `step-pure-*` rules and left non-label behavior intact.
- `br_if + suffix` and `nop + suffix` still produced exactly one Config
  solution.
- direct `label(... br 0)` step had no solution.
- `label(... br 0) local.get 1` suffix search had no solution.
- `steps(fib-config(i32v(5)))` got stuck in the nested frame/label/br shape.
- The strict bridge LHS does match `step((Z ; label(... br 0)))`; an
  unconditional probe over the same LHS rewrote successfully.
- The direct pure rewrite `step-pure(label(... br 0)) => eps` succeeds.
- The blocking point is the conditional rewrite premise
  `step-pure(INSTRS) => INSTRSQ` when `INSTRSQ` is a `WasmTerminals` variable:
  Maude did not bind the collapsed `eps` result for the label/br case. The
  same condition with exact RHS `eps` succeeds.
- Broadening the bridge result variable to `StepPureConf` makes the condition
  solvable, but is not faithful: Maude can satisfy the rewrite condition by the
  zero-step unreduced term `step-pure(...)`, yielding configurations that
  contain `step-pure(...)` as instructions.
- Changing administrative label/frame/handler constructor result sorts did not
  make the strict bridge fire.
- Maude 3.5.1 rejects `=>!` in conditional rewrite premises, so there is no
  built-in non-reflexive rewrite condition available for this bridge.
- The shortcuts were restored because no source-preserving generic replacement
  was identified in this pass.

Question for review: whether C1 may include a generic context-closure / bridge
encoding that is operationally stronger than the strict source-shaped rules, or
whether this belongs in C2 as execution-layer control infrastructure.


## Resolved P1: Sequence-Shaped `Val-ok` Footer Leftover

- Previous classification: executable harness/prelude leftover.
- Current state: removed from strict core after focused ablation.
- Remaining `eq` / `ceq ... = valid` rows: 0.

The removed footer overload/equations were not singleton source-rule targets.
Source-generated singleton `Val-ok` primary `crl`s remain. Accepted Fibonacci
execution smokes still pass without the sequence-shaped list-lifting equations.
Empty and multi-value `Val-ok` probes now remain stuck, which is documented as
an executable validation-list limitation rather than hidden by footer equations.

## P1: Footer / Prelude Genericity Debt

The footer still contains generic prelude pieces, Wasm-specific support, and
executable harness scaffolding. Examples include frame/store representation
helpers, finite type-iteration helpers, and list-lifting support outside the
removed `= valid` validation equations. This should be separated before broader
non-Wasm SpecTec generalization.

## P1: `Step/ctxt-instrs` Executability Limitation

The strict single generated `step-ctxt-instrs` rule is structurally present,
but plain Maude rewriting does not always compose the needed inner `Step`
premise in label cases. The current focused ablation shows that the immediate
blocker is already visible at the generic `crl [step-pure]` bridge for
label-shaped instruction terms. This is documented in `limitation.md`.

## P2: Label Fidelity Anomalies

The following source rules have primary rules but labels include generated `w-` artifacts or similar token sanitation effects:

- `wasm-3.0/2.1-validation.types.spectec:179` `Rectype_ok/_rec2` -> `[rectype-ok-w--rec2]`
- `wasm-3.0/2.2-validation.subtyping.spectec:159` `Fieldtype_sub/var` -> `[fieldtype-sub-w-var]`
- `wasm-3.0/2.2-validation.subtyping.spectec:218` `Globaltype_sub/var` -> `[globaltype-sub-w-var]`
- `wasm-3.0/2.3-validation.instructions.spectec:63` `Instr_ok/if` -> `[instr-ok-w-if]`


These are likely harmless for semantics but are not ideal for professor-facing source-to-output mapping.

## P2: Generated Category/Free Predicates

`$is-spectec-*` and `$free-*` families are generated helper infrastructure for broad-carrier Maude terms. They are source-category-derived but not themselves SpecTec source constructs.

## Possible Generic Translator Bugs

No definite missing construct was found. The label-fidelity anomalies above are plausible generic cleanup candidates, not semantic blockers.
