# Spec2Maude Artifact Evaluation

This document provides a short reviewer workflow followed by the commands for
the larger WebAssembly core-suite evaluation.

All commands are run from the repository root. Complete
[INSTALL.md](INSTALL.md) first.

## Artifact inputs

The artifact pins both external inputs:

```sh
cat spectec/REVISION
cat benchmarks/wasm-spec/REVISION
```

The expected commits are:

```text
SpecTec:             acc6e834ff403c82554d081237f327346190ad96
WebAssembly suite:   fc209c5ed8afc4dfeb9252024d217da3376c7a6f
```

The SpecTec copy contains only the listed library subset, WebAssembly
specification chapters 0--4, and Spec2Maude-specific source annotations. The
benchmark copy contains only the official `test/core` suite.

## Reviewer smoke test

### 1. Build all OCaml targets

```sh
dune build
```

Expected result: exit status 0 and no compiler error.

### 2. Test the complete SpecTec-to-Maude translation

```sh
test/spectec_to_maude.sh
```

If Maude is not on `PATH`, provide its absolute path:

```sh
MAUDE=/absolute/path/to/maude test/spectec_to_maude.sh
```

The test performs one complete pipeline:

- confirms that the pinned source contains exactly 21 `.spectec` files;
- parses and elaborates all 21 files through `bin/spec2maude.exe`;
- generates a fresh temporary Maude module;
- checks that it is byte-for-byte identical to
  `translator/generated/output.maude`;
- loads that fresh module together with all hand-written backends in Maude;
- rejects every Maude warning, advisory, or error.

Expected final output:

```text
spectec_to_maude: PASS (21 files)
```

### 3. Regenerate the versioned semantics manually

```sh
dune exec bin/spec2maude.exe --
```

This reads `spectec/wasm-3.0/*.spectec` in lexical order and writes
`translator/generated/output.maude`. The preceding test uses a temporary file
and does not modify the repository.

## Command-line frontends

Show the SpecTec translator interface:

```sh
dune exec bin/spec2maude.exe -- --help
```

Show the WebAssembly frontend interface:

```sh
dune exec bin/wasm2maude.exe --
```

The second command prints its command summary and exits nonzero because no
subcommand was selected.

## Official WebAssembly core suite

The pinned suite contains 258 `.wast` files, including the `bulk-memory`,
`exceptions`, `gc`, `memory64`, `multi-memory`, `relaxed-simd`, and
`simd` sub-suites.

### Audit frontend coverage

```sh
dune exec bin/wasm2maude.exe -- suite-audit \
  benchmarks/wasm-spec/test/core
```

This checks discovery, parsing, validation, and encoding of the official test
inputs without executing Maude.

Expected output:

```text
files: 258
modules: 2510
encoded: 2510
```

### Run the suite

```sh
test/wasm_core_suite.sh
```

If Maude is not on `PATH`, or a fixed result directory is desired:

```sh
MAUDE=/absolute/path/to/maude \
RESULT_DIR=/tmp/spec2maude-wasm-core \
test/wasm_core_suite.sh
```

The script verifies that the suite contains exactly 258 distinct `.wast`
files. It first runs all files with a 300-second wall-clock timeout and then
reruns only `TIMEOUT` files with a 3600-second timeout. It uses a rewrite
budget of `1000000000000` to make the runner's required bounded `rew` argument
non-limiting in practice, and uses call depth 256.

The result directory contains the first-stage report and logs, every retry's
command/report/log, and the merged `final.tsv` and `summary.tsv`. `final.tsv`
contains:

```text
status  seconds  commands  checked_assertions  runtime_assertions  source  detail
```

Each file is classified as one of:

- `PASS`;
- `WRONG_RESULT`;
- `UNSUPPORTED`;
- `FRONTEND_ERROR`;
- `MAUDE_ERROR`;
- `TIMEOUT`;
- `STEP_LIMIT`;
- `STUCK`.

The script exits with status 0 only when all 258 scripts are classified as
`PASS`. Otherwise it exits nonzero after preserving the complete reports and
logs; a nonzero exit therefore does not mean that the experiment artifacts
were lost.

## Interpreting failures

- A build error is an OCaml dependency or compilation failure.
- A SpecTec-to-Maude test failure means parsing, elaboration, translation,
  reproducibility, or complete Maude loading failed.
- A suite status other than `PASS` is preserved in the TSV report and must
  not be silently counted as success.

## Cleaning generated build state

```sh
dune clean
```

This removes Dune build products. It does not remove the versioned generated
semantics or benchmark inputs.
