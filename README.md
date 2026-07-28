# Spec2Maude

Spec2Maude translates WebAssembly SpecTec into Maude.

The project is a research artifact for deriving rewriting-logic semantics from
structured language specifications.  The current input is the WebAssembly 3.0
SpecTec source under `wasm-3.0/`; the output is a Maude module that can be
loaded, rewritten, searched, and eventually model checked.

The intended pipeline is:

```text
wasm-3.0/*.spectec
  -> SpecTec parser / elaborator
  -> SpecTec IL
  -> Spec2Maude
  -> output.maude
  -> Maude
```

For WebAssembly programs, the generated semantics are meant to be used with a
separately generated initial Maude configuration:

```text
.wat / .wasm
  -> WebAssembly parser / validator
  -> initial Maude configuration
  -> output.maude
  -> rewrite / search / model checking
```

## Repository Layout

```text
bin/           command-line entry point
translator/    SpecTec-to-Maude translator
wasm_to_maude/ WebAssembly-to-Maude initial configuration frontend
builtins.maude hand-written builtin backend semantics
builtins.contract builtin backend ABI metadata
wasm-3.0/      WebAssembly 3.0 SpecTec source
wat_examples/  small local WebAssembly examples
legacy/        previous implementation attempts, kept only for reference
```

`output.maude` and any copy requested with `--builtins` are generated artifacts.

## Build

Requirements:

- OCaml / opam
- Dune
- Maude

Build the translator:

```sh
dune build
```

## Translate

Generate Maude from the default WebAssembly SpecTec source:

```sh
dune exec ./bin/spec2maude.exe -- translate \
  -o output.maude \
  --builtins output-builtins.maude
```

If no input files are provided, Spec2Maude reads `wasm-3.0/*.spectec` in lexical
order.  Explicit files can also be passed:

```sh
dune exec ./bin/spec2maude.exe -- translate \
  -o output.maude \
  wasm-3.0/1.1-syntax.values.spectec
```

## Check

Translate and instantiate a validated WebAssembly module with the generated
semantics:

```sh
dune exec ./bin/wasm2maude.exe -- module wat_examples/fib-wrapper.wat
dune exec ./bin/wasm2maude.exe -- instantiate wat_examples/fib-wrapper.wat
```

The first command checks the encoded module against `syn.module`. The second
rewrites the official SpecTec `instantiate` definition; modules with imports
require an explicit host-address mapping and are rejected for now.

Audit the module payloads in a local checkout of the official WebAssembly test
suite with:

```sh
dune exec ./bin/wasm2maude.exe -- suite-audit \
  benchmarks/external/webassembly-spec/test/core
```

This audit covers WAT and binary module decoding, validation, and Maude term
encoding. Execution of WAST commands such as `invoke` and `assert_return` is a
separate runner stage.

Execute each WAST script independently in Maude and write a tab-separated report:

```sh
dune exec ./bin/wasm2maude.exe -- suite-run \
  benchmarks/external/webassembly-spec/test/core \
  --timeout 60 \
  --log-dir /tmp/spec2maude-suite-logs \
  -o /tmp/spec2maude-suite.tsv
```

The report distinguishes passing scripts, wrong results, unsupported inputs,
frontend failures, Maude errors, timeouts, and stuck executions.  The command exits
nonzero unless every selected script passes.

Load the generated modules in Maude:

```sh
maude -no-banner output.maude
maude -no-banner output-builtins.maude
```

Run the OCaml test suite:

```sh
dune runtest
```
