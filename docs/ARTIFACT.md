# Spec2Maude Artifact Evaluation

This document covers dependency installation, a short reviewer workflow, and
the larger WebAssembly core-suite evaluation.

All commands are run from the repository root.

## Installation

### Requirements

Spec2Maude requires:

- a Unix-like environment;
- OCaml 5.1.0;
- Dune 3.0 or newer;
- Menhir;
- Zarith;
- Maude 3.5.1.

The artifact has been tested on macOS arm64 with:

```text
OCaml   5.1.0
Dune    3.23.1
Menhir  20260209
Zarith  1.14
Maude   3.5.1
```

### Install the OCaml dependencies

Install [opam](https://opam.ocaml.org/), then create a switch and install the
required packages:

```sh
opam switch create 5.1.0 ocaml-base-compiler.5.1.0
eval "$(opam env --switch=5.1.0)"
opam install dune.3.23.1 menhir.20260209 zarith.1.14
```

An existing compatible switch may be used instead. Confirm the active tools:

```sh
ocamlc -version
dune --version
menhir --version
```

### Install Maude

Install Maude 3.5.1 from the
[official Maude distribution](https://maude.cs.illinois.edu/), then make the
`maude` executable available on `PATH`.

Confirm that it starts:

```sh
maude
```

The banner should report `Maude 3.5.1`. Enter `quit` to exit.

Alternatively, set `MAUDE` to the executable path when running the supplied
SpecTec-to-Maude test:

```sh
MAUDE=/absolute/path/to/maude test/spectec_to_maude.sh
```

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
specification chapters 0--4, and Spec2Maude-specific hint annotations.
Function bodies and rules remain those of the pinned upstream source.
The benchmark copy contains only the official `test/core` suite.

## Reviewer smoke test

### 1. Build all OCaml targets

```sh
dune build
```

This builds `bin/spec2maude.exe`, the SpecTec IL-to-Maude translator, and
`bin/wasm2maude.exe`, the WebAssembly configuration and test-script frontend.
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
- generates a fresh temporary `output.maude` file;
- checks that it is byte-for-byte identical to its counterpart in
  `translator/generated/`;
- loads that file together with all hand-written backends in Maude;
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
`translator/generated/output.maude`.
With `-o FILE`, the generated module is written to `FILE`. The preceding test
uses a temporary directory and does not modify the repository.

### 4. Load the complete Maude semantics manually

`translator/backend/semantics.maude` owns the complete loading order:

1. SpecTec representation support;
2. generated semantics;
3. hand-written relation backends;
4. primitive builtin semantics.

Load it from the repository root:

```sh
maude -no-banner translator/backend/semantics.maude
```

A successful load produces no warning or advisory. Enter `quit` to exit.

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

### Reusable Wasm calls in a composed model

`module` encodes a `.wat`/`.wasm` module (`--term-only` emits just the term).
`instantiate` emits an instantiation request. `run` adds initialization and a
fixed invocation; `modelcheck` also adds returned-value propositions and queries.
These load `translator/backend/semantics.maude`, which loads the generated
`translator/generated/output.maude` and backend support. `.wast` scripts use
`wast-run` for their modules, actions, and assertions.

The fixed rules for `run` and `modelcheck` are in
`wasm2maude/run-runtime.maude` and `wasm2maude/modelcheck-runtime.maude`.
The generated modules import these rules and supply the module, invocation,
and query data. Both commands emit an absolute runtime path resolved from
the working directory; `--runtime FILE` selects a different location.

The shared WAST execution rules are hand-written in
`wasm2maude/wast-runtime.maude`. The generated `WASM2MAUDE-WAST` module imports
this runtime and supplies the input commands, host data, and initial state.
Both `wast-run` and `suite-run` resolve that default path against the working
directory and emit an absolute `load` path. Use `--wast-runtime FILE` when
running from another directory or relocating the runtime. This path is
independent of `--semantics FILE`, which selects the translated Wasm semantics.

Use `harness` when another Maude model must supply arguments and consume results:

```sh
dune exec bin/wasm2maude.exe -- harness \
  modelchecking/simple-distributed/client.wasm --invoke client_step \
  --module-name CLIENT-WASM --prefix client \
  -o modelchecking/simple-distributed/client.maude
dune exec bin/wasm2maude.exe -- harness \
  modelchecking/simple-distributed/server-buggy.wasm --invoke server_step \
  --module-name SERVER-BUGGY-WASM --prefix server \
  -o modelchecking/simple-distributed/server-buggy.maude
maude modelchecking/simple-distributed/distributed-system.maude
```

The generated modules expose `clientCall(ARGS) =>* clientResult(RESULT)` and
`serverCall(ARGS) =>* serverResult(RESULT)`. All generated operators, state sorts,
and rule labels use the requested prefix. Choose distinct module names and
prefixes when composing modules. Names start with a letter and contain only
letters, digits, or hyphens. The enclosing file loads `semantics.maude` once,
then the harness files; harness files contain no `load`, execution, or LTL queries.

Each call **creates a fresh instance**, finishes initialization (including any
start function), then invokes the chosen export through the generated `Step`
relation. The caller must supply arguments matching the export signature.
Only a returned value list reaches `Result`; a trap or divergence is not a
successful result. Host imports are currently rejected. Store changes do not
persist between calls. For a stateful application, model the persistent store
and invocation lifecycle explicitly.

The distributed example treats each successful Wasm call as one protocol action
by using it in a rewrite condition. Its functions terminate and carry protocol
state through numeric arguments. This does not expose instruction-level
interleavings or model arbitrary trapping/diverging calls. Network behavior,
fairness assumptions, and propositions remain in `distributed-system.maude`.
Its `2+` counter saturation is not an exact abstraction of wrapping i32
arithmetic; the short duplicate-processing counterexample occurs before
saturation. Fairness-conditioned liveness is a conditional claim about this
finite protocol model.

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

## Model-checking claims

The `modelcheck` command generates an initialization/invocation wrapper around
the translated `Step` relation. It currently observes returned numeric values.
`<> returned(expected)` is universal eventual return, while
`[] ~ returned(rejected)` excludes only that particular returned value; it is
not a trap-freedom or termination claim. `search` checks existence separately.

`--steps N` bounds the generated preliminary rewrite and search commands. It
does **not** bound the following `modelCheck` calls. Record a separate process
timeout and distinguish it from a completed model-checking result. Maude
totalizes deadlocks for LTL; inspect the trace to distinguish a source trap,
program divergence, and an unexpected stuck configuration.

The current backend uses the documented Wasm DET profile. The current
`modelcheck` CLI rejects imported modules because it does not supply the
host-address mapping needed to initialize them.
See [translation and hint contracts](TRANSLATION.md) for the supported scope
and assumptions.
A completed target check is not by itself a proof of source-level preservation.

## Profiling

Use Maude's profiler to identify costs in the command being measured:

```maude
set profile on .
--- Run the command being measured.
show profile .
```

Record the input, command, tool versions, bounds, and process timeout alongside
the profile. Rewrite counts alone do not establish a bottleneck or a speedup.

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
