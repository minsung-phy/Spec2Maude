# C1 Header / Footer / Prelude Audit

Updated: 2026-05-20

## Scope

This audit classifies non-source-derived or infrastructure-like artifacts in the
current generated C1 output and its supporting prelude:

- `output_bs.maude`
- `dsl/pretype.maude`
- fixed header/footer strings in `translator_bs.ml`
- benchmark-only harness pieces in `wasm-exec-bs.maude`

This audit now includes the focused dead-helper cleanup completed on
2026-05-20. No source semantics were changed.

## Required Checks

```bash
grep -n "Func-ok\|Instrs-ok\|Module-ok\|Externaddr-ok\|fib\|CTORI32A0" translator_bs.ml
```

Result: no output.

```bash
grep -nE "^[[:space:]]*(eq|ceq) .* = valid" output_bs.maude
```

Result: no output.

```bash
grep -n "iter-empty\|opt-empty" output_bs.maude
```

Result: no output.

```bash
grep -n "step-from-step-pure-" output_bs.maude | wc -l
```

Result: `20`.

## Inventory Summary

Detailed inventory: `prelude_inventory.csv`.

| Classification | Count |
|---|---:|
| `GENERIC_SPECTEC_PRELUDE` | 17 |
| `SOURCE_DERIVED` | 10 |
| `NON_C1_FINAL_SCAFFOLD` | 8 |
| `WASM_SPECIFIC_SEMANTICS` | 5 |
| `EXECUTION_HARNESS` | 5 |
| `BENCHMARK_HARNESS` | 4 |
| `DEAD_CAN_REMOVE` | 4 |
| `LEGACY_OR_DEAD` | 1 |
| `UNKNOWN` | 2 |
| **Total inventory rows** | **56** |

These counts are artifact-family counts, not source coverage counts. Source
coverage remains as previously audited: syntax 249 / 249, defs 1272 / 1272,
relations 82 / 82, and rules 499 / 499.

## Generic SpecTec Prelude

The following pieces are good candidates for a reusable SpecTec prelude, after
renaming or parameterization:

- terminal carrier sorts and sequence sorts:
  `WasmTerminal`, `WasmTerminals`, `WasmType`, `WasmTypes`;
- sequence support:
  `eps`, sequence concatenation, `len`, `index`, list update;
- record support:
  `item`, record literals, `value`, record update, append/update helpers;
- type/category witness support:
  `TypedTerm`, `WellTyped`, `_hasType_`;
- relation proof-result support:
  `Judgement`, `ValidJudgement`, `valid`;
- generated category predicates:
  `$is-spectec-*`;
- generic list type witness:
  `cmb (LIST-TS hasType (list(LIST-TY))) : WellTyped ...`.

Main cleanup need: rename or parameterize the `Wasm*` carrier names. They are
currently generic in role but Wasm-specific in spelling.

## Wasm-Specific Semantics

These pieces are either source-derived from the Wasm SpecTec files or fixed
support for Wasm-specific source constructs:

- Wasm syntax constructors and syntax membership rules;
- source-generated definitions and relation rules;
- `Config`, `State`, `Store`, and `Frame` source syntax from
  `4.0-execution.configurations.spectec`;
- Wasm index/numeric subsorts such as `Labelidx`, `Localidx`, `Funcidx`, etc.;
- fixed type atoms such as `w-N`, `w-M`, `w-X`, `w-C`;
- specialized administrative constructors for `LABEL`, `FRAME`, and `HANDLER`;
- source execution helpers such as `$invoke`, `$instantiate`, `$local`,
  `$with-local`, and `$with-locals`.

These are acceptable in Wasm output, but the hardcoded header pieces should not
be assumed for non-Wasm SpecTec inputs.

## Execution Harness

Current execution-oriented infrastructure includes:

- `StepConf`, `StepPureConf`, `StepReadConf`, `StepsConf`;
- `step`, `step-pure`, `step-read`, and `steps` wrapper result sorts/operators;
- `$is-spectec-val-seq`, generated for source `val*` guards from the SpecTec
  `val` category rather than from a hardcoded value-constructor list;
- `CTORFRAMEA2` and its projection/update equations for the source frame record
  syntax `{ LOCALS ..., MODULE ... }`;
- current frame/store representation helpers.

Some of this is needed to keep the accepted C1 execution smokes working. It is
not all direct source syntax, so it should be separated from the strict core
story or justified as a generic relation-compilation layer.

## Benchmark Harness

Benchmark artifacts are cleanly outside `translator_bs.ml` and live in
`wasm-exec-bs.maude`:

- `fib-store`;
- `fib-module`, `fib-moduleinst`, `fib-funcinst`;
- `fib-config`, `fib-config-invoke`;
- `fib-body`, `fib-loop-body`;
- `i32v`;
- CTORI32A0-specific harness membership.

These are allowed as benchmark harness code. They should not migrate into the
translator or the generated strict core.

## Non-C1-Final Scaffolding

Known non-C1-final scaffolding in the generated output/header/footer:

- 20 label-related `step-from-step-pure-*` shortcuts;
- sequence-lifting footer helpers for `$subst-typeuse`, `$subst-valtype`, and
  `$subst-subtype`. These are not standalone source defs, but they currently
  implement SpecTec `f(x)*` sequence-map uses inside the source substitution
  equations;
- `$expanddt` footer shortcut over `$unrolldt`.

The old `$mk-frame` adapter has been removed. It is now represented by the
source-derived `CTORFRAMEA2` constructor. The remaining debt is genericity: this
typed constructor pattern should be generated from source record syntax instead
of being tied to the Wasm frame fields in the translator.

The removed sequence-shaped `Val-ok` footer list-lift confirms the cleanup
pattern: first ablate one helper family, then keep it removed only if accepted
execution smokes still pass.

A focused ablation of the `$subst-*` list lifts was attempted. Accepted
Fibonacci smokes still passed, but source-level substitution probes regressed:
`$subst-subtype` over a subtype sequence stopped reducing. The lifts therefore
remain for now as non-C1-final scaffolding until the translator has a generic
source-preserving lowering for SpecTec sequence-map expressions.

## Removed Dead Artifacts

The following artifacts were classified as `DEAD_CAN_REMOVE` and removed from
the active generator. They no longer appear in `translator_bs.ml` or
`output_bs.maude`, and accepted execution smokes still pass:

- `$cfg-state` / `$cfg-instrs`:
  old config projection helpers;
- `needs-label-ctxt`:
  old label-control detector from the disabled heating/cooling experiment;
- `is-trap`:
  old trap detector from the disabled heating/cooling experiment;
- stale `VALOK-WT-S`, `VALOK-C`, `VALOK-NT` variables:
  leftovers after footer `Val-ok` cleanup;
- disabled `ExecConf` / `restore-label` / `restore-frame` /
  `restore-handler` branch in `translator_bs.ml`.
- broad `$local` / `$with-local` footer shims:
  duplicate equations over the current concrete state representation. The
  source-generated `$local` and `$with-local` definitions remain and handle the
  accepted execution smokes.
- finite type-iteration helpers `$rec-typevars`, `$def-typeuses`, and
  `$idx-typeuses`:
  source-absent helpers that were only emitted as their own declarations and
  equations. Regeneration and accepted smokes pass without them.

The only remaining `LEGACY_OR_DEAD` inventory item is `DSL-EXEC` in
`dsl/pretype.maude`, which is outside the generated `output_bs.maude` core and
should be audited separately before removal.

## Recommended Cleanup Order

1. Generalize the `CTORFRAMEA2` frame record lowering so typed record
   constructors are derived from source record syntax rather than a Wasm frame
   special case.
2. Design generic source-preserving lowering for sequence-map expressions such
   as `$subst_valtype(t, tv*, tu*)*`, then replace the hardcoded `$subst-*`
   list lifts.
3. Refresh stale header comments that still mention old `eq/ceq ... = valid`
   baseline behavior.
4. Parameterize the carrier/prelude names away from `Wasm*`.
5. Generate administrative constructor specializations from source shapes rather
   than hardcoded constructor names.
6. Keep benchmark harness artifacts isolated in `wasm-exec-bs.maude`.

## Items That Should Move Out Of Strict C1 Core

- benchmark harness terms and CTORI32A0 conveniences;
- execution-only helpers that do not correspond to source constructs;
- label-related `step-from-step-pure-*` shortcuts, unless professor approves a
  generic source-preserving bridge in C1;
- frame/store representation scaffolding if it becomes an execution adapter
  rather than source translation;
- list-lifting scaffolding if retained only for executability.

## Current Recommendation

Do not make broad semantic changes yet. The first dead-artifact ablation and the
duplicate `$local` / `$with-local` footer-shim ablation both passed.
Move next to the higher-risk footer helpers one family at a time. Keep
structural coverage and executability as separate claims.
