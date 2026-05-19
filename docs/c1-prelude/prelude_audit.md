# C1 Header / Footer / Prelude Audit

Updated: 2026-05-20

## Scope

This audit classifies non-source-derived or infrastructure-like artifacts in the
current generated C1 output and its supporting prelude:

- `output_bs.maude`
- `dsl/pretype.maude`
- fixed header/footer strings in `translator_bs.ml`
- benchmark-only harness pieces in `wasm-exec-bs.maude`

No source semantics or translator code was changed for this audit.

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
| `LEGACY_OR_DEAD` | 5 |
| `WASM_SPECIFIC_SEMANTICS` | 5 |
| `EXECUTION_HARNESS` | 5 |
| `BENCHMARK_HARNESS` | 4 |
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
- `is-val` and `all-vals`;
- `$mk-frame` and its projection/update equations;
- broad record-state shims for `$local` and `$with-local`;
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
  `$subst-subtype`;
- finite type-iteration helpers:
  `$rec-typevars`, `$def-typeuses`, `$idx-typeuses`;
- `$expanddt` footer shortcut over `$unrolldt`;
- `$mk-frame` representation helper;
- broad `$local` / `$with-local` footer shims.

The removed sequence-shaped `Val-ok` footer list-lift confirms the cleanup
pattern: first ablate one helper family, then keep it removed only if accepted
execution smokes still pass.

## Likely Legacy Or Dead Artifacts

The following appear unused in current `output_bs.maude` or are disabled in the
translator:

- `DSL-EXEC` in `dsl/pretype.maude`:
  older evaluation-context infrastructure, not used by current generated C1;
- `$cfg-state` / `$cfg-instrs`:
  declared and defined, but no use found beyond their equations;
- `needs-label-ctxt`:
  declared and defined, but no use found in current generated rules;
- `is-trap`:
  declared and defined, but no use found in current generated rules;
- stale `VALOK-WT-S`, `VALOK-C`, `VALOK-NT` variables:
  remain after sequence `Val-ok` cleanup, no use found;
- disabled `ExecConf` / `restore-label` / `restore-frame` /
  `restore-handler` branch in `translator_bs.ml`.

These are strong cleanup candidates, but they should be removed only after a
small ablation/regression pass for each family.

## Recommended Cleanup Order

1. Remove trivially unused footer/header declarations after a focused ablation:
   `$cfg-state`, `$cfg-instrs`, `needs-label-ctxt`, `is-trap`, and stale
   `VALOK-*` variables.
2. Remove or archive the disabled `ExecConf restore-*` branch in
   `translator_bs.ml` if there is no plan to revive it.
3. Audit `$local` and `$with-local` footer shims against the source-generated
   equations; remove only if execution smokes still pass.
4. Audit `$mk-frame` representation helper separately; it is high-impact and
   tied to the current frame/store representation.
5. Audit sequence-lifting helpers for `$subst-*`; decide whether they are C1
   structural support or C2 executable scaffolding.
6. Audit finite type-iteration helpers `$rec-typevars`, `$def-typeuses`, and
   `$idx-typeuses`; replace with generic source-preserving iterator lowering if
   possible.
7. Refresh stale header comments that still mention old `eq/ceq ... = valid`
   baseline behavior.
8. Parameterize the carrier/prelude names away from `Wasm*`.
9. Generate administrative constructor specializations from source shapes rather
   than hardcoded constructor names.
10. Keep benchmark harness artifacts isolated in `wasm-exec-bs.maude`.

## Items That Should Move Out Of Strict C1 Core

- benchmark harness terms and CTORI32A0 conveniences;
- execution-only helpers that do not correspond to source constructs;
- label-related `step-from-step-pure-*` shortcuts, unless professor approves a
  generic source-preserving bridge in C1;
- frame/store representation scaffolding if it becomes an execution adapter
  rather than source translation;
- finite-iteration and list-lifting scaffolding if retained only for
  executability.

## Current Recommendation

Do not make broad semantic changes yet. Start with dead-artifact ablations, then
move to the higher-risk footer helpers one family at a time. Keep structural
coverage and executability as separate claims.
