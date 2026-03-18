<p align="center">
  <img src="https://img.shields.io/badge/SpecTec→Maude-Formal%20Translation-blue?style=for-the-badge" alt="SpecTec to Maude" />
</p>

<h1 align="center">Spec2Maude</h1>

<p align="center">
  <strong>Zero-Hardcoding, Pure-Functional Translation of WebAssembly 3.0 SpecTec to Maude Algebraic Specifications</strong>
</p>

<p align="center">
  <a href="https://ocaml.org"><img src="https://img.shields.io/badge/OCaml-5.x-EC6813?logo=ocaml" alt="OCaml" /></a>
  <a href="https://maude.cs.illinois.edu"><img src="https://img.shields.io/badge/Maude-3.x-0066CC" alt="Maude" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License: MIT" /></a>
</p>

<p align="center">
  <em>From executable Wasm semantics to executable formal models — no manual encoding, no global state.</em>
</p>

---

## Overview

**Spec2Maude** is a fully automatic translator that compiles the [WebAssembly 3.0](https://webassembly.github.io/spec/) SpecTec formal specification into a Maude algebraic specification. It preserves the logical integrity of the original semantics while producing a runnable formal model suitable for verification, model checking, and mechanized reasoning.

Unlike ad-hoc text transformers, Spec2Maude operates directly on the elaborated IL AST, ensuring that type constraints, small-step rules, and arithmetic primitives are faithfully encoded as Maude equations and predicates.

---

## Key Achievements

| Achievement | Description |
|-------------|-------------|
| **Monadic Variable Collection** | Global state eliminated: the `texpr` record carries both Maude text and collected variables through pure functional composition. No mutable accumulators during expression translation. |
| **Zero Hardcoded Tokens** | A single 1-pass AST pre-scan collects all bare tokens from mixfix patterns and emits `ops TOKEN1 TOKEN2 ... : -> WasmTerminal [ctor] .` automatically. No instruction-name lists baked into the translator. |
| **59 Core Semantics Tests** | Equational unit tests cover arithmetic (`$iadd`, `$binop`), type-checking (`is-type`), record operations, and `Step-pure` predicates. All reduce to expected values. |
| **Executable Confluence** | Fibonacci(7)=13 and 2¹⁰=1024 run to completion on the `WASM-EXEC` stepping engine (387–772 rewrites), proving deterministic convergence to `halt(push(result, emptystack))`. |

---

## Quick Start

```bash
# Build
dune build

# Translate Wasm 3.0 SpecTec → Maude
dune exec ./main.exe -- path/to/wasm-3.0/*.watsup > output.maude

# Run equational tests (59 reductions)
maude test/test-core.maude

# Execute Wasm programs (Fibonacci, arithmetic)
maude test/wasm-exec.maude
```

**Full installation, build, and tutorial walkthrough** → [**Execution Guide**](document/Execution_Guide.md)

---

## Architecture at a Glance

```
*.watsup  →  Parse  →  Elaborate  →  IL AST  →  Spec2Maude  →  output.maude
                                                      │
                                    ┌─────────────────┴─────────────────┐
                                    │  Pre-scan (1 pass)                 │
                                    │  • Tokens, ctors, call signatures │
                                    │  • Bool-context inference          │
                                    └─────────────────┬─────────────────┘
                                                      │
                                    ┌─────────────────┴─────────────────┐
                                    │  Translation (pure functional)    │
                                    │  • texpr = { text; vars }          │
                                    │  • TypD → op + is-type eq/ceq      │
                                    │  • DecD → op + eq/ceq              │
                                    │  • RelD → op → Bool + ceq = true   │
                                    └───────────────────────────────────┘
```

**Formal translation rules, mapping notation, and confluence analysis** → [**Formal Translation Rules**](document/Translation_Rules.md)

---

## Repository Structure

```
Spec2Maude/
├── main.ml                 # Entry: parse → elaborate → translate
├── translator.ml           # Core translator (SpecTec IL → Maude)
├── dune                    # Build configuration
├── dsl/
│   └── pretype.maude       # Foundation sorts, records, type combinators
├── output.maude            # Generated SPECTEC-CORE module
├── test/
│   ├── test-core.maude     # 59 equational unit tests
│   └── wasm-exec.maude     # Executable stepping engine prototype
├── document/
│   ├── Execution_Guide.md  # Build, run, tutorial
│   └── Translation_Rules.md # Formal rules, architecture, examples
└── README.md
```

---

## Prerequisites

| Dependency | Purpose |
|------------|---------|
| OCaml 5.x | Translator implementation |
| dune | Build system |
| Maude 3.x | Rewriting logic engine |
| SpecTec libs (`il`, `util`, `frontend`) | Parsing and elaboration |

---

## License

Copyright © 2026 Minsung Lee (POSTECH SVLab). Licensed under the [MIT License](LICENSE).
