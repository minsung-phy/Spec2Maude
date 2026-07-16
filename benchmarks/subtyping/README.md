# Certified SubE regression

Run `./run.sh` from any directory. The check translates the full Wasm SpecTec
input and verifies the audited `SubE` slice in generated Maude:

- both `$minat` address operands retain their coercions;
- both `$unpackfield_` execution occurrences inject `val` into `instr`;
- the `addrtype` to `valtype` helper has exactly the two certified source cases;
- `val` pattern projection is performed after a fresh target pattern is bound;
- target-only values have no projection equation, fallback, or `[owise]` case.

The assertions inspect source-originated declarations and equations rather than
duplicating translator implementation logic.
