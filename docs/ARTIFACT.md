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

## Five-minute smoke test

### 1. Build all OCaml targets

```sh
dune build
```

Expected result: exit status 0 and no compiler error.

### 2. Run the translation smoke test

```sh
dune runtest test --force
```

Expected output includes:

```text
translated 21 SpecTec files into 585165 Maude bytes
Bye.
```

The OCaml test parses and elaborates all 21 SpecTec files, recursively
translates the IL AST, and checks the generated module and support import. The
shell test loads the complete semantics in Maude and fails if Maude emits a
warning, advisory, or error.

The Maude test is skipped when `maude` is unavailable. For artifact
evaluation, first confirm:

```sh
command -v maude
```

### 3. Regenerate and compare the semantics

```sh
tmp_output="$(mktemp)"
dune exec bin/spec2maude.exe -- -o "$tmp_output"
cmp translator/generated/output.maude "$tmp_output"
rm -f "$tmp_output"
```

Expected result: `cmp` exits with status 0.

The expected SHA-256 of the generated file is:

```text
1d2afca0a72722e0edfd8ba48419688229873cc819aeae195743efe0b37deae5
```

On systems with `sha256sum`:

```sh
sha256sum translator/generated/output.maude
```

On macOS:

```sh
shasum -a 256 translator/generated/output.maude
```

### 4. Load Maude independently

```sh
test/maude_load.sh "$(pwd)"
```

Expected result: exit status 0, `Bye.`, and no warning or advisory.

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
mkdir -p /tmp/spec2maude-suite-logs
dune exec bin/wasm2maude.exe -- suite-run \
  benchmarks/wasm-spec/test/core \
  --semantics translator/backend/semantics.maude \
  --maude maude \
  --timeout 60 \
  --steps 1000000 \
  --call-depth 256 \
  --log-dir /tmp/spec2maude-suite-logs \
  -o /tmp/spec2maude-suite.tsv
```

The TSV report contains:

```text
status  seconds  commands  runtime_assertions  source  detail
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

The command exits with status 0 only when every selected script is classified
as `PASS`. Per-file Maude logs are written to the requested log directory.

## Interpreting failures

- A build error is an OCaml dependency or compilation failure.
- A translation-smoke failure means parsing, elaboration, translation, or the
  generated module boundary changed.
- A Maude-load failure means the generated and hand-written modules do not
  compose without diagnostics.
- A checksum mismatch means the generated semantics is not byte-for-byte
  reproducible from the pinned inputs.
- A suite status other than `PASS` is preserved in the TSV report and must
  not be silently counted as success.

## Cleaning generated build state

```sh
dune clean
```

This removes Dune build products. It does not remove the versioned generated
semantics or benchmark inputs.
