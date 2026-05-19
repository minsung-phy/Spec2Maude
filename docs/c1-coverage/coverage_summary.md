# C1 Full Coverage Summary

Updated: 2026-05-20

## Scope

Audited all active source constructs in `wasm-3.0/*.spectec` against `output_bs.maude`:

- syntax declarations;
- def declarations/equations;
- relation declarations;
- rule declarations.

Block-commented `(; ... ;)` source text was ignored for source-target counts.

## Coverage Counts

| Construct kind | Found | Covered | Missing | Notes |
|---|---:|---:|---:|---|
| Source files | 21 | 21 | 0 | All `wasm-3.0/*.spectec` files included |
| Syntax declarations | 249 | 249 | 0 | Declaration-level sort/predicate/operator coverage |
| Def declarations/equations | 1272 | 1272 | 0 | Operator/equation/rewrite evidence found |
| Relation declarations | 82 | 82 | 0 | Generated relation operators found |
| Rule declarations | 499 | 499 | 0 | Primary `rl`/`crl` coverage; 4 label anomalies |

## Validation Lowering Confirmation

- 281 / 281 strict source-rule targets are primary Maude `rl`/`crl` rules.
- No source target remains as `eq`/`ceq ... = valid`.
- No `iter-empty` or `opt-empty` derived validation labels remain.
- The sequence-shaped `Val-ok` footer/harness list-lift has been removed from
  strict C1.
- No `eq`/`ceq ... = valid` rows remain.

Current exact `= valid` leftover grep:

```bash
grep -nE "^[[:space:]]*(eq|ceq) .* = valid" output_bs.maude
```

Expected/current result: no output.

## Step/ctxt-instrs Confirmation

- Strict source-shaped `step-ctxt-instrs` exists.
- Label-related `step-from-step-pure-*` shortcuts remain as executable debt: 20 labels.
- Non-label `step-from-step-pure-*` shortcuts found: 0.

## Hardcoding / Condition Checks

Required checks from this audit:

- `grep -n "Func-ok\|Instrs-ok\|Module-ok\|Externaddr-ok\|fib\|CTORI32A0" translator_bs.ml`: no output.
- `grep -n "if .* = true" output_bs.maude`: no output.
- `grep -n "== valid = true" output_bs.maude`: no output.

Representative variable naming remains visible in generated rules, e.g. `STEP-CTXT-INSTRS2-INSTRS`, `STEP-CTXT-INSTRS2-INSTRSQ`, and `STEP-CTXT-INSTRS2-VALS` in `step-ctxt-instrs`.

## Known Missing / Suspicious Items

No active source syntax, def, relation, or rule construct was found missing in this static audit.

Suspicious / non-isomorphic items are documented in `non_isomorphic_items.md`:

- label-related `step-from-step-pure-*` executable debt;
- removed sequence-shaped `Val-ok` footer/harness leftover, now recorded as a
  strict sequence-probe executability limitation;
- footer/prelude genericity debt;
- `Step/ctxt-instrs` executability limitation;
- four label-fidelity anomalies.

## Recommended Next Fixes

1. Review `non_isomorphic_items.md` and `limitation.md` with the professor.
2. Decide whether remaining execution-oriented helpers belong in C1 or C2.
3. Audit footer/prelude separation, especially frame/store helpers and finite
   type-iteration support.
4. Investigate label-fidelity anomalies if professor-facing source-to-output traceability needs exact label normalization.
5. Keep executable failures separate from structural coverage unless a generic translator bug is proven.
