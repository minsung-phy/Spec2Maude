# Spec2Maude

Spec2Maude translates WebAssembly SpecTec into Maude.  The current target is
the WebAssembly 3.0 SpecTec source under `wasm-3.0/`.

The goal is not to hand-write another WebAssembly interpreter.  The goal is to
derive a Maude rewriting-logic artifact from the same structured specification
used by SpecTec, while keeping the generated Maude close enough to the source
that each generated declaration, equation, or rule can be explained.

This repository is developed as a research artifact for studying executable
rewriting-logic semantics generated from SpecTec.

## Overview

The main translation path is:

```text
wasm-3.0/*.spectec
  -> SpecTec parser / elaborator
  -> Il.Ast.script
  -> Spec2Maude translator
  -> output.maude
  -> Maude load / rewrite / search / model checking
```

The generated Maude semantics are intended to sit in the following execution
pipeline for WebAssembly programs:

```text
.wat / .wasm program
  -> official WebAssembly parser / validator
  -> Wasm AST
  -> Maude initial configuration
  -> output.maude semantics
  -> Maude rewriting
```

## Translation Principles

Spec2Maude follows two core principles.

First, the translation should be source-isomorphic where possible.  A SpecTec
type, expression, premise, relation, or rule should leave a recognizable trace
in the generated Maude.  The translator keeps origin and provenance metadata in
its internal Maude IR so generated code can be traced back to SpecTec source or
IL nodes.

Second, the translation should be source-driven rather than WebAssembly-name
driven.  The translator is written against constructors in `lib/il/ast.ml` and
the shape of SpecTec IL.  It must not special-case particular WebAssembly
instruction names, type names, relation names, or rule names to decide
translation behavior.

When a source construct requires an explicit backend policy, Spec2Maude emits a
structured diagnostic instead of guessing.

## Implementation

The active translator is the root `translator` library.  It replaces the older
monolithic legacy translator with a typed, source-driven backend:

- typed Maude IR before text emission;
- source origins and provenance for generated statements;
- source-readable naming such as `syn-instr`, `numtype.i32`, and `steps`;
- constructor registry for emitted SpecTec constructors and projections;
- separation between type, expression, premise, relation, Maude, and builtin
  translation code;
- Maude builtin obligation tracking for `hint(builtin)` declarations.

The generated Maude currently consists of:

- `output.maude`: source-derived SpecTec/Maude translation;
- `builtins.maude`: backend implementations or obligations for
  `hint(builtin)` primitives;
- `docs/BUILTIN_OBLIGATIONS.md`: generated builtin status report.

The backend is organized around source-level definitions (`TypD`, `DecD`,
`RelD`), expression and premise lowering, typed Maude statement construction,
and explicit builtin obligations.  This keeps the generated Maude close to the
SpecTec structure while still separating backend concerns such as naming,
prelude generation, builtin rendering, and diagnostics.

## Repository Layout

```text
bin/                    command-line entry point
translator/             active SpecTec-to-Maude translator
translator/core/        origins, diagnostics, context, naming
translator/source/      source indexes, static keys, relation/type shape data
translator/maude/       typed Maude IR, emitter, prelude, registry
translator/lower/       TypD, DecD, RelD, expression, pattern, premise lowering
translator/builtin/     builtin registry, report, and Maude rendering
wasm-3.0/               WebAssembly 3.0 SpecTec source
legacy/                 previous implementations, reference only
docs/                   implementation contract and generated reports
wat_examples/           local WAT examples
output.maude            generated source-derived Maude module
builtins.maude          generated builtin backend module
```

The implementation contract is
[`docs/IMPLEMENTATION_PLAN_V2.md`](docs/IMPLEMENTATION_PLAN_V2.md).

Legacy code is kept only for comparison.  It is not ground truth for the new
translator.

## Requirements

You need:

- OCaml and opam;
- Dune;
- Maude;
- the SpecTec frontend libraries in this repository.

Example OCaml setup:

```sh
opam switch create spec2maude 5.2.0
eval "$(opam env --switch=spec2maude)"
opam install dune menhir
```

If you already have a suitable switch:

```sh
eval "$(opam env)"
```

Maude must be available on `PATH`:

```sh
command -v maude
```

## Build

```sh
dune build
```

## Generate Maude

Translate the default WebAssembly 3.0 SpecTec files:

```sh
dune exec ./bin/spec2maude.exe -- translate \
  -o output.maude \
  --builtins builtins.maude \
  --builtin-report docs/BUILTIN_OBLIGATIONS.md
```

If no input files are provided, the translator reads `wasm-3.0/*.spectec` in
lexical order.

You can also translate an explicit set of SpecTec files:

```sh
dune exec ./bin/spec2maude.exe -- translate -o output.maude wasm-3.0/1.1-syntax.values.spectec
```

## Maude Load Check

```sh
maude -no-banner output.maude
maude -no-banner builtins.maude
```

Warnings are treated as artifact issues.  The translator should not generate
ill-formed Maude, rewrite conditions inside equations, or fake builtin default
equations.

## Builtins

SpecTec uses `hint(builtin)` for primitives whose meaning must be supplied by a
backend.  Spec2Maude treats these as backend obligations.

Implemented builtins are emitted in `builtins.maude` with Maude equations or
conditional equations.  Backend primitive status is tracked in
`docs/BUILTIN_OBLIGATIONS.md`, and fake defaults such as `0`, `eps`, or
`false` are intentionally avoided.

The generated report currently classifies 86 builtin declarations into
implemented entries and backend obligations.

## Development Notes

The translator is intentionally modular.  New translation rules should be added
near the AST constructor they lower, and unclear cases should remain explicit
diagnostics.  In particular:

- do not copy legacy translator code;
- do not silently erase source constructs;
- do not add instruction-specific hacks;
- do not treat legacy output as correct;
- keep helper encodings source-preserving and documented.

The local SpecTec implementation at `/Users/minsung/Dev/projects/spectec` is
used as an OCaml style reference: direct pattern matching, small helper
functions, disciplined recursion, and clear module boundaries.

## Citation

This repository is part of ongoing research on translating structured language
specifications into rewriting-logic artifacts.  Citation information will be
added with the accompanying paper.
