# Relation And Rule Coverage

Updated: 2026-05-20

## Summary

- Active source `relation` declarations found: 82
- Relation declarations covered by generated Maude operators: 82
- Active source `rule` declarations found: 499
- Source rules covered by primary generated `rl`/`crl`: 499
- Missing source rules: 0
- Label-renamed/suspicious but structurally covered source rules: 4

## Validation Subset

The strict validation-lowering subset remains confirmed:

- 281 / 281 strict source-rule targets are primary Maude `rl`/`crl` rules.
- No source validation target remains as `eq`/`ceq ... = valid`.
- No `iter-empty` or `opt-empty` derived validation labels remain.

## Label-Renamed Source Rules

These rules are structurally covered by primary `crl`s, but their generated labels are not a direct source-token normalization:

- `wasm-3.0/2.1-validation.types.spectec:179` `Rectype_ok/_rec2` -> `[rectype-ok-w--rec2]`
- `wasm-3.0/2.2-validation.subtyping.spectec:159` `Fieldtype_sub/var` -> `[fieldtype-sub-w-var]`
- `wasm-3.0/2.2-validation.subtyping.spectec:218` `Globaltype_sub/var` -> `[globaltype-sub-w-var]`
- `wasm-3.0/2.3-validation.instructions.spectec:63` `Instr_ok/if` -> `[instr-ok-w-if]`


These are not missing rules. They are label-fidelity anomalies to consider for later cleanup.

## Execution Limitations

Execution limitations are not counted as missing coverage. Known classes include empty `*` premises, witness synthesis in `Instrs-ok/seq`, concrete store/harness lookup, and the `Step/ctxt-instrs` AC-split/conditional-rewrite limitation.
