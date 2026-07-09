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
wasm-3.0/      WebAssembly 3.0 SpecTec source
wat_examples/  small local WebAssembly examples
legacy/        previous implementation attempts, kept only for reference
```

Generated files such as `output.maude` and `builtins.maude` are build artifacts.

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
  --builtins builtins.maude
```

If no input files are provided, Spec2Maude reads `wasm-3.0/*.spectec` in lexical
order.  Explicit files can also be passed:

```sh
dune exec ./bin/spec2maude.exe -- translate \
  -o output.maude \
  wasm-3.0/1.1-syntax.values.spectec
```

## Check

Load the generated modules in Maude:

```sh
maude -no-banner output.maude
maude -no-banner builtins.maude
```

Run the OCaml test suite:

```sh
dune runtest
```
