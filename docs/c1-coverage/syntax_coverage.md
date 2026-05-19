# Syntax Coverage

Updated: 2026-05-20

## Summary

- Source files audited: 21
- Source `syntax` declarations found: 249
- Covered at generated declaration level: 249
- Missing generated category/operator evidence: 0

This audit checks each active `syntax` declaration against generated Maude category evidence: a generated sort, `$is-spectec-*` predicate, or direct operator where applicable. Constructor alternatives are represented in `output_bs.maude` through generated `CTOR...` operators and membership declarations; representative examples include `CTORCONSTA2`, `CTORNOPA0`, and `CTORMODULEA11`.

## Classification

All active source syntax declarations are classified as `SOURCE_SYNTAX_COVERED` in `coverage_matrix.csv`.

## Notes

- Sequence/list representation is centralized through `WasmTerminals` and `eps`.
- Source category guards use generated `$is-spectec-<sort>` predicates to avoid collisions with real source helpers.
- This is a declaration-level structural audit. Deeper constructor-by-constructor arity proof would require reconstructing multi-line SpecTec alternatives exactly; no missing category evidence was found in this pass.
