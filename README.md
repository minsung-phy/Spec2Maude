# Spec2Maude

Spec2Maude is a research prototype for translating **SpecTec** language
definitions into executable **Maude** rewriting-logic specifications.

The current case study is **WebAssembly 3.0**.  The project is aimed at a
research artifact, not a production Wasm runtime.

## Goal

SpecTec gives a structured, machine-readable definition of WebAssembly.  This
project translates that definition into Maude so that the semantics can be
executed, searched, and eventually model checked.

The intended pipeline is:

```text
WebAssembly SpecTec source
  -> Spec2Maude translator
  -> output.maude
  -> Maude execution/search/model-checking backend

.wat / .wasm input program
  -> official SpecTec/WebAssembly parser + validator
  -> WAT/Wasm-to-Maude frontend
  -> Maude module term
  -> init/config harness
  -> steps(...)
  -> result
```

The `.wat` / `.wasm` frontend uses the official WebAssembly parser and
validator from the SpecTec repository, vendored under `vendor/wasm`.
After validation, the frontend lowers the official `Wasm.Ast.module_` into
Maude constructor terms.  The frontend now covers the local smoke programs and
has lowering coverage for many WebAssembly 3.0 instruction families, including
numeric/control/local/global/memory/table/ref plus SIMD, GC, array/struct, and
exception-related AST constructors.  Remaining failures in large benchmarks are
mostly runtime execution, result-comparison, import/WASI, or proposal-coverage
issues rather than the old hand-written WAT parser path.

## Artifact-Evaluation Snapshot

Use the root CLI for the short PLDI-style sanity check:

```bash
make build
./spec2maude translate -o output.maude
python3 scripts/audit_syntax_translation.py output.maude --source-dir wasm-3.0
maude -no-banner output.maude
maude -no-banner wasm-exec.maude
./spec2maude run wat_examples/fib.wat --fib 5
./spec2maude test smoke --timeout 10
```

Current expected results on 2026-06-09:

```text
syntax audit                 PASS
maude output.maude           PASS, warnings: 9, fatal diagnostics: 0
maude wasm-exec.maude        PASS, warnings: 9, fatal diagnostics: 0
fib.wat --fib 5              result: const(i32, 5)
local smoke suite            PASS: 13
```

The remaining Maude warnings are parser-ambiguity warnings, not load errors.
They are tracked in [docs/limitation.md](docs/limitation.md).  The current
warning baseline is intentionally kept in a source-readable form: numeric
guards such as `0 <= I` are not rewritten into Maude's internal `_<=_` prefix
notation merely to hide warnings.

## Important Design Choice

The default runtime path does **not** use translated `Module-ok` as the
execution gate.

Instead:

1. invalid `.wat` / `.wasm` input is rejected before Maude execution by the
   official SpecTec/WebAssembly validator;
2. Maude receives a validated module term;
3. Maude executes the dynamic semantics through `steps(...)`.

`Module-ok`, `Func-ok`, `Instr-ok`, and related validation relations are still
present in the full generated SpecTec core because they are part of the source
definition.  They are not the default runtime gate for the WAT/Wasm frontend.

## Repository Layout

```text
translator.ml          active SpecTec-to-Maude translator
main.ml                translator entry point
output.maude           generated WebAssembly Maude core
builtins.maude            Maude backend/builtin definitions
wasm-init.maude        init/config/runtime harness outside output.maude
wasm-exec.maude        execution smoke harness
wasm_to_maude.ml          .wat/.wasm frontend
vendor/wasm/              vendored official SpecTec/WebAssembly parser/validator
spec2maude.ml             reproducible CLI wrapper source
wat_examples/             small local WAT examples
wasm-3.0/                 WebAssembly 3.0 SpecTec source files
scripts/                  benchmark/smoke runner
docs/                     testing notes and current limitations
ARTIFACT.md               artifact-review checklist and expected outputs
legacy/old-baseline/      archived older translator/runtime path
```

Generated/build artifacts are intentionally ignored:

```text
_build/
artifacts/
spec2maude
```

## Requirements

You need:

- OCaml and opam
- Dune
- Maude
- Menhir, used by the vendored official Wasm text parser
- WABT `wast2json` only if you want to run official `.wast` spec-test slices

On macOS:

```bash
brew install opam dune wabt
```

Maude must be installed separately if it is not already on your `PATH`.

```bash
command -v maude
```

If needed:

```bash
export MAUDE_BIN=/path/to/maude
```

## OCaml Setup

Create an opam switch if you do not already have one:

```bash
opam switch create spec2maude 5.2.0
eval "$(opam env --switch=spec2maude)"
opam install dune menhir
```

If you already have a working switch:

```bash
eval "$(opam env)"
```

## Build

```bash
make build
```

This builds the OCaml tools and creates the root executable:

```text
./spec2maude
```

## Quick Start

Translate the SpecTec source into Maude:

```bash
./spec2maude translate
```

Run Fibonacci from WAT:

```bash
./spec2maude run wat_examples/fib.wat --fib 5
```

Expected result:

```text
result: const(i32, 5)
```

Validate a WAT/Wasm input before Maude execution:

```bash
./spec2maude validate wat_examples/fib.wat
```

Show invalid input rejection:

```bash
make validate-invalid
```

Run local smoke tests:

```bash
./spec2maude test smoke --timeout 10
```

Run a small official spec-test slice:

```bash
./spec2maude test official --limit 20 --timeout 10
```

## CLI Commands

```text
./spec2maude translate [-o FILE] [SPECTEC...]
./spec2maude run INPUT.wat|INPUT.wasm [--fib N | --main | --export NAME]
./spec2maude validate INPUT.wat|INPUT.wasm
./spec2maude maude-validate INPUT.wat|INPUT.wasm
./spec2maude test smoke|official|all [--limit N] [--timeout SEC]
```

`maude-validate` is an experimental debug command for the translated
`Module-ok` path.  It is not the recommended execution path.

## Make Targets

```bash
make help
make check-tools
make build
make translate
make run-fib
make validate-invalid
make test-smoke
make test-official LIMIT=20 TIMEOUT=10
```

## Current Status

The active C1 baseline currently has:

- Maude loading with no errors, bad tokens, or no-parse diagnostics;
  parser-ambiguity warnings remain because the generated code preserves
  source-readable constructors and sequence syntax;
- local smoke examples for functions, globals, memory, tables, data, elements,
  starts, and imports;
- official SpecTec/WebAssembly parser-validator based `.wat` / `.wasm` input;
- official AST lowering coverage for core scalar instructions plus many
  SIMD/GC/exception constructors;
- a benchmark runner that records parse/validation/runtime status buckets and
  handles the main numeric, vector, and GC/reference expected-result forms;
- a separated default path where WAT/Wasm validation happens before Maude and
  Maude focuses on dynamic execution.
- a JHS-style syntax carrier where source category witnesses are generated as
  `syn-* : SpectecType` terms and concrete syntax constructors are generated as
  source-readable `SpectecTerminal` terms such as `const(i32, 5)`;
- automatic source-derived constructor disambiguation for reused source heads,
  for example `func-externidx`, `func-externtype`, and `func-func`.
- automatic source-derived argument-shape suffixes for constructor heads that
  have both nullary and argument-taking cases in the same source category, for
  example `div-binop` versus `div-sx-binop` and `le-relop` versus
  `le-sx-relop`.

See:

- [ARTIFACT.md](ARTIFACT.md) for the reviewer-facing checklist;
- [STATUS.md](STATUS.md) for the current project state;
- [docs/HowToTest.md](docs/HowToTest.md) for reproducible commands;
- [docs/limitation.md](docs/limitation.md) for limitations and discussion
  points.

## Research Caveat

This project is still a prototype.  The main open research question is how to
keep the generated Maude close to the SpecTec source while still making the
semantics executable enough for benchmark-scale WebAssembly programs.
