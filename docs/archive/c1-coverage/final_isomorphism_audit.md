# Final C1 Isomorphism Audit Before Executable Testing

Updated: 2026-05-20

This audit checks the current generated `output_bs.maude` against
`wasm-3.0/*.spectec` as a structural source-to-output baseline. It is not an
executability test.

## Required Checks

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

```bash
grep -n "Func-ok\|Instrs-ok\|Module-ok\|Externaddr-ok\|fib\|CTORI32A0" translator_bs.ml
```

Result: no output.

## Source To Output Summary

The existing coverage matrix remains the source-to-output authority for active
source constructs:

| Construct kind | Source count | Covered | Missing | Current status |
|---|---:|---:|---:|---|
| Source files | 21 | 21 | 0 | complete |
| Syntax declarations | 249 | 249 | 0 | complete |
| Def declarations/equations | 1272 | 1272 | 0 | complete |
| Relation declarations | 82 | 82 | 0 | complete |
| Rule declarations | 499 | 499 | 0 | complete |

Detailed evidence:

- `docs/c1-coverage/coverage_matrix.csv`
- `docs/c1-coverage/syntax_coverage.md`
- `docs/c1-coverage/def_coverage.md`
- `docs/c1-coverage/rule_coverage.md`

### Syntax

Source syntax declarations are represented by generated Maude sorts,
constructors, memberships, and generated category predicates. Constructor-level
coverage is complete: 249 / 249 syntax declarations are covered.

Sequence/list representation is consistent with the current broad-carrier
encoding: `eps` and associative sequence concatenation represent SpecTec `*`
forms, with generated category/membership evidence for list-shaped syntax.
This is structural evidence, not a claim that every list-shaped premise is
executable by plain rewriting.

### Def

Source definitions have generated operator/equation/rewrite evidence:
1272 / 1272 def targets are covered.

The previous DecD argument-lowering bug class, where syntax/type parameters
could be dropped or mistranslated, is not currently present in the audited
artifacts. The known `$setminus` issue was fixed by using source argument
translation for DecD LHS arguments; `$setminus(localidx, eps, eps)` now reduces
to `eps`. No additional dropped-argument anomaly is recorded in the current
coverage matrix.

The substitution sequence lifts are classified as accepted representation
substrate for SpecTec star-map notation such as `f(x)*`; the old finite
type-iteration helpers have been removed from the strict output. Remaining
output-to-source extras are classified below.

### Relation And Rule

Source relation operators exist for 82 / 82 active relation declarations.
Active source rules are covered by 499 / 499 primary generated `rl` / `crl`
rules.

Strict validation lowering is complete:

- 281 / 281 strict validation source-rule targets are primary `rl` / `crl`;
- no source validation target remains as `eq` / `ceq ... = valid`;
- no derived validation labels `iter-empty` or `opt-empty` remain;
- previously known label-fidelity anomalies are resolved.

Execution failures such as empty `*` premise cases, `Instrs-ok/seq` witness
synthesis, and concrete harness lookup are not counted as missing translation.
They are strict executability limitations documented in `limitation.md`.

## Output To Source Summary

The source-derived core is structurally complete, but `output_bs.maude` is not a
pure source-only rendering. It still contains artifact families that are
prelude, wrapper, Wasm-specific support, execution harness, benchmark harness,
or non-C1-final scaffolding.

Detailed artifact-family inventory:

- `docs/c1-coverage/generated_extra_artifacts.csv`
- `docs/c1-prelude/prelude_inventory.csv`
- `docs/c1-prelude/prelude_audit.md`

Classification summary for the new generated-extra inventory:

| Classification | Meaning in this audit |
|---|---|
| `SOURCE_DERIVED` | generated from source syntax/def/relation/rule, sometimes with wrapper adaptation |
| `GENERIC_SPECTEC_PRELUDE` | reusable infrastructure needed to encode SpecTec terms, records, lists, categories, or judgement results |
| `WASM_SPECIFIC_SEMANTICS` | Wasm-shaped fixed support or source-derived Wasm helper with extra fixed assumptions |
| `EXECUTION_HARNESS` | support needed for current executable rewriting but not direct source syntax/rule text |
| `BENCHMARK_HARNESS` | Fibonacci harness outside `translator_bs.ml` and outside generated strict core |
| `NON_C1_FINAL_SCAFFOLD` | derived shortcuts or helper equations that are not direct source constructs |
| `LEGACY_OR_DEAD` | appears unused or left over from older experiments |
| `UNKNOWN` | source provenance not fully classified; no current generated strict-core artifact remains in this class |

## Non-Source-Derived Or Partially Source-Derived Items

### Generic Prelude

These are not source constructs, but they are reasonable C1 infrastructure if
documented and eventually renamed/parameterized:

- `WasmTerminal`, `WasmTerminals`, `WasmType`, `WasmTypes`;
- `Judgement`, `ValidJudgement`, `valid`;
- `eps`, sequence concatenation, `len`, `index`, `slice`;
- record utilities `item`, `value`, update, `merge`;
- `_hasType_`, `TypedTerm`, `WellTyped`;
- `$is-spectec-*` generated category predicates.

Main issue: several generic roles still carry `Wasm*` names.

### Wasm-Specific Semantics Or Fixed Header Support

These are acceptable for the Wasm output but block generic SpecTec claims until
they are generated or parameterized:

- fixed index/category sorts such as `Labelidx`, `Localidx`, `Typeidx`,
  `Funcidx`, etc.;
- fixed atoms such as `w-N`, `w-M`, `w-K`, `w-X`, `w-C`;
- specialized administrative constructor declarations for `LABEL`, `FRAME`,
  and `HANDLER`;
- source-derived `$local` / `$with-local` helpers remain Wasm-specific because
  they operate on `LOCALS`, but their broad footer duplicate shims were removed.

### Execution Harness / Relation Compilation Layer

These are needed for current execution. They are accepted as representation
substrate rather than source-rule duplication:

- `StepConf`, `StepPureConf`, `StepReadConf`, `StepsConf`;
- wrapper-return adaptation for `step`, `step-pure`, `step-read`, `steps`;
- `$is-spectec-val-seq`, a generated source-category sequence predicate for
  SpecTec `val*` guards;
- `CTORFRAMEA2`, the typed constructor for the source frame record syntax;
- some frame/store representation equations.

### Non-C1-Final Scaffolding

These violate strict source-only isomorphism most directly:

- 20 label-related `step-from-step-pure-*` shortcuts.

The `$subst-typeuse`, `$subst-valtype`, and `$subst-subtype` sequence lifts are
now treated as accepted C1 representation substrate for SpecTec `f(x)*`
star-map notation. The old `$expanddt` footer shortcut has been removed; only
the source-generated `$expanddt` definition remains.

### Removed Dead Helpers

The following helper artifacts were removed in the focused dead-helper cleanup
after this audit's initial pass:

- `$cfg-state`;
- `$cfg-instrs`;
- `needs-label-ctxt`;
- `is-trap`;
- stale `VALOK-*` variables left after sequence `Val-ok` footer cleanup;
- `$rec-typevars`, `$def-typeuses`, and `$idx-typeuses`.

They no longer appear in `translator_bs.ml` or regenerated `output_bs.maude`.
Build/regeneration and accepted execution smokes still pass.

### Benchmark Harness

Fibonacci artifacts are outside the generated strict core and outside
`translator_bs.ml`:

- `fib-store`;
- `fib-module`, `fib-moduleinst`, `fib-funcinst`;
- `fib-config`, `fib-config-invoke`;
- `i32v`;
- CTORI32A0-specific harness membership.

These are harness artifacts, not C1 source translation. They are acceptable as
long as they remain isolated.

## Strict C1 Violations

See `docs/c1-coverage/c1_violation_priority.md` for the ordered list.

The highest-priority violation is the 20 label-related
`step-from-step-pure-*` rules. They are derived shortcuts from Step_pure into
Step, not direct source rules. They are currently required by accepted
execution; prior removal broke the label/br suffix case and Fibonacci.

Other strict-cleanliness issues are mostly footer/prelude separation and
genericity:

- hand-written footer/header strings that should become generated generic
  substrate;
- frame typed-record lowering that should be generated from source record
  syntax generically;
- legacy/dead helpers that can likely be removed after focused ablation.

## Items That Are Executability Limitations, Not Missing Translation

Do not mark these as missing source-to-output coverage:

- empty `*` premise failures such as `Resulttype-ok(C, eps)`;
- `Instrs-ok/seq` intermediate witness synthesis;
- `Step/ctxt-instrs` conditional rewrite / label suffix execution failure;
- concrete `Externaddr-ok` / `fib-store` lookup and record-shape issues;
- sequence `Val-ok` probes after removing footer list lifting.

These preserve source structure but need either a stronger generic execution
encoding, mode-aware solving, harness cleanup, or a C2 execution layer.

## What Can Be Removed Now?

The obvious generated dead-helper set has now been removed. The next cleanup
targets are higher-risk footer/prelude families, so they should still be tested
one family at a time. The 20 label-related shortcuts should not be removed
again without either a source-preserving generic repair or a professor decision
to accept the resulting execution loss.

## Final Answer

The current output is source-to-output complete for the Wasm 3.0 SpecTec input:
every active source syntax declaration, def target, relation declaration, and
rule declaration has a generated counterpart, and strict validation lowering is
complete.

The current output is not fully strict C1-isomorphic in the output-to-source
direction. It still contains generic prelude infrastructure, Wasm-specific fixed
header support, execution wrapper/harness machinery, benchmark harness terms,
legacy/dead helpers, and non-C1-final scaffolding. The most important
non-isomorphic generated artifacts are the 20 label-related
`step-from-step-pure-*` shortcuts. The previous `$expanddt` footer shortcut has
been removed, and substitution sequence lifts are treated as accepted
source-star-map representation substrate.
