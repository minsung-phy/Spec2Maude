# Spec2Maude Artifact Evaluation

This document covers dependency installation, a short reviewer workflow, and
the larger WebAssembly core-suite evaluation.

All commands are run from the repository root.

## Installation

### Requirements

Spec2Maude requires:

- a Unix-like environment;
- OCaml 5.4 or newer (required by the pinned SpecTec);
- Dune 3.0 or newer;
- Menhir;
- Zarith;
- Maude 3.5.1.

The artifact has been tested on macOS arm64 with:

```text
OCaml   5.4.1
Dune    3.24.2
Menhir  20260209
Zarith  1.14
Maude   3.5.1
```

### Install the OCaml dependencies

Install [opam](https://opam.ocaml.org/), then create a switch and install the
required packages:

```sh
opam switch create spec2maude ocaml-base-compiler.5.4.1
eval "$(opam env --switch=spec2maude)"
opam install dune.3.24.2 menhir.20260209 zarith.1.14
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
cat benchmarks/wasm-spec-2.0/REVISION
cat benchmarks/wasm-spec-1.0/REVISION
```

The expected commits are:

```text
SpecTec:                 e22ec2272bfbc06b995b00c1f1172a61d613fdd8
WebAssembly suite:       e22ec2272bfbc06b995b00c1f1172a61d613fdd8
WebAssembly 2.0 suite:   fffc6e12fa454e475455a7b58d3b5dc343980c10 (wg-2.0)
WebAssembly 1.0 suite:   977f97014c962f7bd1291fcc6d28b41a924882bf (wg-1.0)
```

The SpecTec copy contains only the listed library subset, the WebAssembly 3.0
specification chapters 0--4, the 1.0 and 2.0 specifications without the
binary format, and Spec2Maude-specific hint annotations. Function bodies and
rules remain those of the pinned upstream source, except two 2.0 fixes
reported upstream (spectec/REVISION, docs/TRANSLATION.md "Upstream reports"). The benchmark copies contain
only the official `test/core` suites: `wasm-spec` at the pinned commit (3.0),
and `wasm-spec-2.0`, `wasm-spec-1.0` at the upstream tags `wg-2.0` and `wg-1.0`.

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

The test performs one complete pipeline for each of Wasm 3.0, 2.0, and 1.0:

- confirms the number of pinned `.spectec` files (21 for 3.0, 9 for 2.0 and 1.0);
- parses and elaborates them through `bin/spec2maude.exe`;
- generates fresh temporary `types.maude` and `output.maude` files;
- checks that both are byte-for-byte identical to their counterparts in
  `translator/generated/` (3.0) or `translator/generated/wasm-VERSION/`;
- loads them with the hand-written backend and that version's builtins
  (`translator/backend/main.maude`, `main-wasm-2.0.maude`, `main-wasm-1.0.maude`);
- rejects every Maude warning, advisory, or error.

Expected final output:

```text
spectec_to_maude: wasm-3.0 PASS (21 files)
spectec_to_maude: wasm-2.0 PASS (9 files)
spectec_to_maude: wasm-1.0 PASS (9 files)
```

### 3. Regenerate the versioned semantics manually

```sh
dune exec bin/spec2maude.exe --
```

This reads `spectec/wasm-3.0/*.spectec` in lexical order and writes
`translator/generated/types.maude` and `translator/generated/output.maude`.
For Wasm 1.0 or 2.0, pass the files and an output path:

```sh
dune exec bin/spec2maude.exe -- -o translator/generated/wasm-2.0/output.maude spectec/wasm-2.0/*.spectec
```
With `-o FILE`, the type declarations are written to `types.maude` beside
`FILE`; that name is reserved for the type declarations. The preceding test
uses a temporary directory and does not modify the repository.

### 4. Load the complete Maude semantics manually

`translator/backend/main.maude` (Wasm 3.0; `main-wasm-2.0.maude` and
`main-wasm-1.0.maude` load the other versions) owns the complete loading order:

1. `spectec-sorts.maude` (common sorts) and the generated `types.maude`;
2. `spectec-semantics.maude`, which loads `spectec-builtin-types.maude` (SpecTec
   built-in type representation), then declares separate convert, list, option,
   tuple, record, array, and map modules (they store the fields marked with
   `hint(maude_array)`, such as memory bytes, as a size and a prelude `ARRAY`,
   and the fields marked with `hint(maude_map)`, such as the store's functions
   and memories and table references, as a size and a prelude `MAP`);
3. generated semantics;
4. primitive builtin semantics, `translator/builtins/wasm-VERSION.maude`
   (module `WASM-BUILTINS`), on the shared `core.maude` and `vector.maude`.

Load it from the repository root:

```sh
maude -no-banner translator/backend/main.maude
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
These load `translator/backend/main.maude`, which loads the generated
`translator/generated/output.maude` and backend support; they use Wasm 3.0
only. `wast-run` and `suite-run` select the version with `--wasm` (below). `.wast` scripts use
`wast-run` for their modules, actions, and assertions.

The fixed rules for `run` and `modelcheck` are in
`wasm2maude/run-runtime.maude` and `wasm2maude/modelcheck-runtime.maude`.
The generated modules import these rules and supply the module, invocation,
and query data. Both commands emit an absolute runtime path resolved from
the working directory; `--runtime FILE` selects a different location.

The WAST execution rules are hand-written in `wasm2maude/`:
`wast-runtime-core.maude` (all versions), `wast-runtime-vector.maude` (2.0
and 3.0: v128 and reference results, `assert_unlinkable`, `table.grow`), and
the driver module of each version, `wast-runtime-3.0.maude`,
`wast-runtime-2.0.maude`, and `wast-runtime-1.0.maude`, which give the memory,
table, and grow shapes of that version. The generated `WASM2MAUDE-WAST` module
imports the driver and supplies the input commands, host data, and initial
state.
Both `wast-run` and `suite-run` resolve that default path against the working
directory and emit an absolute `load` path. Use `--wast-runtime FILE` when
running from another directory or relocating the runtime. This path is
independent of `--semantics FILE`, which selects the translated Wasm semantics.

The WAST runtime is a test runner, not part of the translated semantics:

- It runs one execution per script with `rew`, like the reference
  interpreter. The Step rules rewrite the command's state in place, as in the
  `run` runtime; there is no step bound, and `suite-run --timeout` bounds the
  run. `rew` is rule fair, so where several Step rules apply it may take any of
  them. The reference interpreter grows a memory or table whenever growth can
  succeed: at `memory.grow` and `table.grow` the runtime takes the first
  successor in Maude's search order, the success rule (`choice`). Other
  choices are left to `rew`; use the runner with `rew`, not with `search` or
  model checking.
- `spectest` print functions are an environment model: the specification calls
  a host function through `$hostcall`, and the runtime defines it for the print
  functions, which return no values and leave the store unchanged.
- A table larger than 2^24 references is an environment model, like the
  call-depth bound: the reference interpreter fails to allocate it, so a
  `table.grow` past that size takes the specification's failure rule
  (`Step/table.grow-fail`), which the specification allows at any size.
- SpecTec has no call-stack limit. `assert_exhaustion` passes once the frame
  depth exceeds `--call-depth` (default 256), so that PASS is relative to the
  bound.

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
letters, digits, or hyphens. The enclosing file loads `main.maude` once,
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

The pinned 3.0 suite contains 259 `.wast` files (2.0: 148, 1.0: 73), including the `bulk-memory`,
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
files: 259
modules: 2523
encoded: 2523
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

The script verifies that the suite contains exactly 259 distinct `.wast`
files (148 for 2.0, 73 for 1.0). It first runs all files with a 300-second wall-clock timeout and then
reruns only `TIMEOUT` files with a 3600-second timeout. It uses call depth
256.

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
- `STUCK`.

The script exits with status 0 only when all scripts are classified as
`PASS`. Otherwise it exits nonzero after preserving the complete reports and
logs; a nonzero exit therefore does not mean that the experiment artifacts
were lost.

### Wasm 1.0 and 2.0

```sh
WASM_VERSION=1.0 test/wasm_core_suite.sh
WASM_VERSION=2.0 test/wasm_core_suite.sh
```

`wasm2maude wast-run` and `suite-run` take `--wasm 1.0|2.0|3.0` (default
3.0). It selects the module encoding of that version
(`wasm2maude/encode_v1.ml`, `encode_v2.ml`), the semantics
(`translator/backend/main-wasm-VERSION.maude`), and the WAST runtime
(`wasm2maude/wast-runtime-VERSION.maude`, above). The scripts are parsed, validated,
and decoded by the pinned reference interpreter (Wasm 3.0). For a 1.0 or 2.0
script:

- the script forms the current parser no longer reads are rewritten to their
  current equivalents (`wasm2maude/legacy_wast.ml`): `assert_return_canonical_nan`,
  `assert_return_arithmetic_nan`, and segments with a bare memory or table index;
- an `assert_invalid` or `assert_malformed` module that Wasm 3.0 accepts (a
  feature added after that version) cannot be checked by this front end; it is
  not counted as checked and is listed in the `detail` column as
  `unchecked static assertions: N`. A module that Wasm 3.0 rejects at the
  other stage (malformed in 1.0, invalid in 3.0) is still rejected;
- Wasm 1.0 has no instruction-level segment initialization: a segment that
  does not fit leaves `$instantiate` without a result. `assert_unlinkable`
  then passes when the imports do not link or a search of the semantics finds
  no configuration for the instantiation (`metaSearch` in
  `wast-runtime-1.0.maude`);
- 1.0 and 2.0 have no host functions. A `spectest` print function is a
  function instance with an empty body: it returns no value and changes no
  state, as the spectest functions do for a test.

Expected result (Maude 3.5.1, default timeouts): 1.0 has 72 of 73 files
`PASS` (18413 checked assertions, 25 unchecked static assertions), and 2.0 has
147 of 148 (52209 checked, 21 unchecked). In both, `i64.wast` is `STUCK`: the
shift-amount problem of WebAssembly/spec#2319 (docs/TRANSLATION.md, "Upstream
reports"), so the script exits nonzero.

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
