# Installing Spec2Maude

This document describes how to install the dependencies, build the two
command-line tools, generate the Maude semantics, and load the result.

All commands are run from the repository root.

## Requirements

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

## Install the OCaml dependencies

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

## Install Maude

Install Maude 3.5.1 from the
[official Maude distribution](https://maude.cs.illinois.edu/), then make the
`maude` executable available on `PATH`.

Confirm that it starts:

```sh
maude
```

The banner should report `Maude 3.5.1`. Enter `quit` to exit.

Alternatively, set `MAUDE` to the executable path when running the supplied
Maude smoke test:

```sh
MAUDE=/absolute/path/to/maude test/maude_load.sh "$(pwd)"
```

## Build

```sh
dune build
```

This builds:

- `bin/spec2maude.exe`, the SpecTec IL-to-Maude translator;
- `bin/wasm2maude.exe`, the WebAssembly configuration and test-script
  frontend.

## Generate the semantics

Run Spec2Maude without explicit source arguments:

```sh
dune exec bin/spec2maude.exe --
```

The command reads the 21 `spectec/wasm-3.0/*.spectec` files in lexical order
and writes:

```text
translator/generated/output.maude
```

An alternative output path can be selected with `-o`:

```sh
dune exec bin/spec2maude.exe -- -o /tmp/spec2maude-output.maude
```

## Load the complete Maude semantics

`translator/backend/semantics.maude` owns the complete loading order:

1. SpecTec representation support;
2. generated semantics;
3. hand-written relation backends;
4. primitive builtin semantics.

Load it from the repository root:

```sh
maude -no-banner translator/backend/semantics.maude
```

A successful load produces no warning or advisory. Maude prints `Bye.` when
the input file reaches end of file.

## Next step

See [ARTIFACT.md](ARTIFACT.md) for the reviewer-oriented smoke test,
reproducibility checks, and official WebAssembly test-suite commands.
