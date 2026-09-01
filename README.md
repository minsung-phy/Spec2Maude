# Spec2Maude

Spec2Maude is a research prototype for deriving executable
[Maude](https://maude.cs.illinois.edu/) semantics from
[SpecTec](https://github.com/Wasm-DSL/spectec) language definitions. Its primary
case study is the WebAssembly 3.0 specification.

The project investigates whether a structured language specification can be
translated into rewriting logic by a small, auditable recursive definition
over the SpecTec intermediate language, instead of by a collection of
language-specific translation passes.

## Research Motivation

SpecTec gives mechanized structure to language syntax, auxiliary definitions,
relations, inference rules, and premises. Maude provides executable rewriting
logic with equations, rewrite rules, matching, search, and model checking.

Connecting the two makes a SpecTec specification usable as an executable Maude
semantics. The central challenge is to preserve the source structure while
making every non-direct translation decision visible and reviewable.

## Approach

Spec2Maude parses and elaborates SpecTec with the SpecTec frontend, then
recursively translates the resulting IL abstract syntax tree into a small
Maude intermediate representation.

The translation follows four principles:

1. **Source directed.** Translation decisions are driven by SpecTec IL
   constructors and source annotations, not by WebAssembly instruction or rule
   names.
2. **Structure preserving.** Syntax definitions, deterministic definitions,
   relations, rules, premises, patterns, and iterations retain their source
   structure whenever Maude provides a direct representation.
3. **Explicit at non-direct boundaries.** Source annotations identify
   definitions or relations that require a particular Maude interpretation.
   Hand-written backend semantics remain separate from generated semantics.
4. **Auditable failure.** A construct outside the supported translation
   boundary is rejected explicitly rather than assigned a guessed meaning.

## Translation Pipeline

```text
WebAssembly SpecTec source
        |
        v
SpecTec parser and elaborator
        |
        v
SpecTec IL AST
        |
        v
Recursive Spec2Maude translation
        |
        v
Generated Maude module
        |
        +---- hand-written SpecTec support
        +---- relation backends
        +---- builtin semantics
        |
        v
Executable WebAssembly semantics in Maude
```

A separate WebAssembly frontend translates validated WebAssembly modules and
test scripts into initial Maude terms. This separates the derivation of the
language semantics from the construction of concrete program configurations.

## Repository Organization

```text
bin/                         command-line frontends
spectec/                     pinned SpecTec IL and WebAssembly 3.0 sources
translator/                  recursive SpecTec IL-to-Maude translation
translator/maude/            Maude intermediate language and renderer
translator/generated/        generated Maude semantics
translator/backend/spectec-support/
                             hand-written SpecTec representation support
translator/backend/relation-backends.maude
                             explicitly selected relation implementations
translator/backend/builtins.maude
                             hand-written primitive semantics
translator/backend/semantics.maude
                             complete Maude loading order
wasm2maude/                  WebAssembly-to-Maude configuration frontend
vendor/wasm/                 vendored WebAssembly reference implementation
test/                        SpecTec translation and WebAssembly suite tests
benchmarks/wasm-spec/        pinned official WebAssembly core test suite
```

## Reproducibility and Provenance

Third-party sources are stored as pinned subsets:

- `spectec/REVISION` records the SpecTec upstream commit and the local
  annotation boundary.
- `benchmarks/wasm-spec/REVISION` records the WebAssembly specification
  commit used for the official core test suite.

Their upstream licenses are included alongside the corresponding sources.
Previous translator designs are retained under `legacy/` for historical
reference and are not part of the active translation pipeline.

## Documentation

- [Installation](docs/INSTALL.md)
- [Artifact evaluation and testing](docs/ARTIFACT.md)

## License

Spec2Maude is distributed under the GNU General Public License v3.0. Vendored
third-party components retain their respective upstream licenses.
