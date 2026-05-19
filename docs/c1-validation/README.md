# C1 Validation Audit Artifacts

Updated: 2026-05-20

This directory contains detailed evidence for the strict C1 validation-lowering audit.

The root-level summary is:

- `../../validation_281_summary.md`

Current strict result:

```text
281 strict source-rule targets
-> 281 primary Maude rl/crl rules
```

Strict C1 validation policy:

- one SpecTec source relation rule maps to one primary Maude `rl` / `crl`;
- no derived validation rules;
- no `iter-empty` or `opt-empty`;
- no helper-heavy executable shortcuts in the strict core;
- strict executability failures are limitations unless they come from generic translator bugs.

## Files

- `validation_281_progress.csv`: row-level coverage and concrete-test classification for the 281 strict targets.
- `helper_setminus_audit.md`: focused DecD helper audit and generic DecD LHS lowering fix evidence.
- `footer_valid_leftovers_audit.md`: classification of remaining footer `eq` / `ceq ... = valid` leftovers.

## Batch Reports

The `batches/` directory contains the per-source-file validation passes:

- `validation_2_1_types_report.md`;
- `validation_2_2_subtyping_report.md`;
- `validation_2_3_instructions_report.md`;
- `validation_2_4_modules_report.md`;
- `validation_4_1_values_and_eval_expr_report.md`.

## Archive

The `archive/` directory contains reconciliation evidence from the earlier mechanical count:

- `validation_293_reconciliation.md`;
- `validation_293_reconciliation.csv`.

Those files explain why the old mechanical `293` count became the corrected strict `281` source-target count.
