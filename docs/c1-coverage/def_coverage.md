# Def Coverage

Updated: 2026-05-20

## Summary

- Active source `def` declarations/equations found: 1272
- Covered by generated Maude operator/equation/rewrite evidence: 1272
- Missing: 0

All active source `def` lines have generated Maude evidence in `output_bs.maude`: an operator, an `eq`/`ceq`, or, for output-bearing helper definitions, an `rl`/`crl` style generated artifact.

## Specific Checks

- Syntax/type-parameter arguments such as `syntax X` are preserved in generated helper calls; this includes the previously audited `$setminus` family.
- No current source helper collision was found in this audit. The earlier `$is-<sort>` collision class is avoided by the `$is-spectec-<sort>` predicate namespace.
- `$setminus(localidx, eps, eps)` is covered by generated `$setminus` equations that preserve the syntax argument.

## Limitations

Some defs are structurally represented but not necessarily pleasant as executable equations because they carry output-like witnesses or state-threading structure. Those are classified structurally, not as missing.
