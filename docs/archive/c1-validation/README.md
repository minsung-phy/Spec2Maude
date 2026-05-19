# C1 Validation Audit Artifacts

Updated: 2026-05-20

This directory contains detailed evidence for the strict C1
validation-lowering audit. It is archival evidence, not the first document to
read.

Current reading guide:

- current limitations and decisions: `../../limitation.md`;
- historical validation summary: `../validation_281_summary.md`;
- this directory: detailed audit evidence only.

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

Earlier per-source-file batch reports and reconciliation CSVs were consolidated
into the current summary documents and may no longer exist as standalone root
files.
