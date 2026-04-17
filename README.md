<p align="center">
  <img src="https://img.shields.io/badge/SpecTec→Maude-Formal%20Translation-blue?style=for-the-badge" alt="SpecTec to Maude" />
</p>

<h1 align="center">Spec2Maude</h1>

<p align="center">
  <strong>Automatic Translation of WebAssembly 3.0 SpecTec Formal Semantics into Maude Algebraic Specifications</strong>
</p>

<p align="center">
  <a href="https://ocaml.org"><img src="https://img.shields.io/badge/OCaml-5.x-EC6813?logo=ocaml" alt="OCaml" /></a>
  <a href="https://maude.cs.illinois.edu"><img src="https://img.shields.io/badge/Maude-3.x-0066CC" alt="Maude" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License: MIT" /></a>
</p>

<p align="center">
  <em>From an executable Wasm 3.0 specification to a formal Maude model — syntactic translation is instruction-agnostic; a small hand-written execution harness closes evaluation contexts.</em>
</p>

---

## Overview

**Spec2Maude** is a research-grade compiler that automatically translates the [WebAssembly 3.0](https://webassembly.github.io/spec/) formal specification, written in [SpecTec](https://github.com/Wasm-DSL/spectec), into a runnable Maude rewriting-logic specification. The output is suitable for equational reduction, LTL model checking, and mechanized formal reasoning about WebAssembly program behavior.

The translation pipeline operates directly on the elaborated **Intermediate Language (IL) AST** produced by the SpecTec frontend. Every syntactic category (`syntax`), auxiliary definition (`def`), and operational semantics rule (`relation`) is mapped to its Maude counterpart — sorts, operators, and equations — without any instruction-specific branching in the translator source code.

---

## Current Status

### Translation coverage

| Metric | Value |
|--------|-------|
| SpecTec input files processed | 21 |
| Parser / elaborator warnings | 0 |
| Generated `output.maude` (lines) | 7,065 |
| Total equations (`eq` + `ceq`) | 1,367 |
| Auto-generated `step` equations | 189 |
| Operator declarations | 1,007 |
| Sort / subsort declarations | 307 |

Every `syntax`, `def`, and `relation` declaration in the Wasm 3.0 SpecTec source is consumed without per-instruction branching in `translator.ml`. Evaluation-context wrappers (`exec-label`, `exec-frame`, `exec-handler`, `exec-loop`) and one known soundness patch (`$with-local`) are implemented by hand in [wasm-exec.maude](wasm-exec.maude).

### Verified execution

| Benchmark | Result | Evidence |
|-----------|--------|----------|
| Iterative `fib(5)` | `i32.const 5` | 5,949 rewrites to normal form |
| `<> result-is(5)` | `true` | LTL model check passes |
| `[] ~ trap-seen` | `true` | LTL model check passes |

**Scope caveat.** End-to-end verification currently exercises only the instruction subset used by `fib` (arithmetic, `local.get`/`local.set`, `block`/`loop`/`br_if`, `const`, `relop`/`binop`/`testop`). Memory, table, call/call-indirect, GC, Exception, SIMD, atomic, and the validation relations are syntactically translated but have not been executed against benchmarks.

---

## Architecture Pipeline

```
*.spectec files
      │
      ▼
  SpecTec Frontend
  (Parse → Elaborate)
      │
      ▼
  Elaborated IL AST
      │
      ▼
 ┌────────────────────────────────────────────────┐
 │              translator.ml                      │
 │                                                 │
 │  Phase 1 – Pre-scan (single pass over all defs) │
 │   • Collect bare atom tokens  →  op T : -> WT   │
 │   • Collect relation call signatures → op $f    │
 │   • Infer Bool-context for expression nodes     │
 │                                                 │
 │  Phase 2 – Translation (pure functional)        │
 │   • TypD  →  sort S . / op ctor : args -> S .   │
 │   • DecD  →  op $f : args -> WasmTerminal .     │
 │             + [c]eq $f(lhs) = rhs [if cond] .   │
 │   • RelD (non-Step)                             │
 │          →  op R : args -> Bool .               │
 │             + [c]eq R(lhs) = true [if cond] .   │
 │   • RelD (Step / Step-pure / Step-read)         │
 │          →  [c]eq step(< Z | LHS IS >) =        │
 │                       < Z' | RHS IS > .         │
 └────────────────────────────────────────────────┘
      │
      ▼
  output.maude  (mod SPECTEC-CORE)
      │
      ▼
  wasm-exec.maude
  (mod WASM-EXEC + WASM-FIB + WASM-FIB-PROPS)
      │
      ├─► rewrite [N] : steps(config) .   (equational reduction)
      └─► modelCheck(config, φ) .         (LTL verification)
```

---

## Repository Structure

```
Spec2Maude/
├── main.ml                      # Entry point: parse → elaborate → translate
├── translator.ml                # Core translator (~2000 lines, OCaml)
├── dune / dune-project          # Build configuration
├── lib/                         # SpecTec frontend libraries
│   ├── il/ast.ml                # IL AST definition
│   ├── frontend/                # Parser, elaborator
│   └── ...
├── dsl/
│   └── pretype.maude            # Foundation module (sorts, records, DSL)
├── wasm-3.0/                    # WebAssembly 3.0 SpecTec source files
│   ├── 4.3-execution.instructions.spectec
│   └── ...
├── output.maude                 # Auto-generated SPECTEC-CORE module
├── wasm-exec.maude              # Execution engine + LTL harness
├── docs/
│   ├── Translation_Rules.md        # Formal translation rules (Korean)
│   ├── execution_results.md        # How to run + regression results (Korean)
│   ├── maude_warning_analysis.md   # Warning taxonomy and mitigation roadmap
│   └── experiment_repro.md         # Legacy split doc: reproduction steps
└── README.md
```

---

## Prerequisites

| Dependency | Version | Purpose |
|------------|---------|---------|
| OCaml | ≥ 5.0 | Translator implementation language |
| dune | ≥ 3.0 | Build system |
| Maude | ≥ 3.4 | Rewriting logic engine |
| SpecTec libs | bundled in `lib/` | SpecTec IL parsing and elaboration |

### Installing Maude

Download a pre-built binary from the [Maude releases page](https://github.com/SRI-CSL/Maude/releases) and ensure `maude` is on your `PATH`.

### Installing OCaml and dune

```bash
# via opam
opam install dune
```

---

## Build

```bash
# Clone and enter the repository
git clone https://github.com/<your-org>/Spec2Maude.git
cd Spec2Maude

# Build the translator
dune build

# Run the translator: SpecTec sources → output.maude
./_build/default/main.exe wasm-3.0/*.spectec > output.maude
```

The translator writes the generated Maude module to standard output and diagnostic warnings to standard error. The repository already ships a prebuilt `output.maude` for convenience.

---

## Running the Execution Engine

`wasm-exec.maude` loads `output.maude` and defines:

- **`WASM-EXEC`** — the one-step `step` function and the transitive `steps` operator
- **`WASM-FIB`** — an iterative Fibonacci program encoded in WebAssembly instruction syntax
- **`WASM-FIB-PROPS`** — LTL atomic propositions and model-checking harness

For one-command regeneration plus smoke verification, use:

```bash
./scripts/regen_and_smoketest.sh current
```

If you want automatic fallback (`current` -> `legacy-safe`) when `current` fails:

```bash
./scripts/regen_and_smoketest.sh auto
```

Detailed run instructions and expected outputs are documented in [docs/execution_results.md](docs/execution_results.md).

### Multi-step equational reduction

```maude
load wasm-exec

rewrite [100000] in WASM-FIB : steps(fib-config(i32v(5))) .
```

Expected output (abbreviated):

```
result ExecConf: < ... | CTORCONSTA2(CTORI32A0, 5) >
```

The instruction sequence on the right-hand side of `|` reduces to the single value `i32.const 5`, confirming `fib(5) = 5`.

### LTL Model Checking

```maude
load wasm-exec

--- Property 1: the computation eventually produces result 5
red in WASM-FIB-PROPS : modelCheck(mc-fib-config(i32v(5)), <> result-is(5)) .
--- Expected: Bool: true

--- Property 2: no reachable state ever exhibits a trap
red in WASM-FIB-PROPS : modelCheck(mc-fib-config(i32v(5)), [] ~ trap-seen) .
--- Expected: Bool: true
```

Both properties hold over the complete reachable-state graph of `fib(5)`.

---

## Design Highlights

### 1. Pure-Functional Expression Translation

Every expression node in the IL AST is translated by a function returning `texpr = { text : string; vars : string list }`. The `vars` field accumulates free variables without any global mutable state, enabling compositional variable collection and premise scheduling.

### 2. Instruction-Agnostic Token Collection

A dedicated pre-scan pass collects every bare atom that appears as a mixfix operator component (e.g., `i32`, `add`, `local.get`). These are emitted as nullary `op TOKEN : -> WasmTerminal [ctor]` declarations — no instruction name list is baked into the translator. The one explicit exception is `$rollrt`, which is bridged in a single hardcoded branch to cross the IL/Maude sort boundary.

### 3. Step-Relation Auto-Translation

The translator identifies `Step`, `Step-pure`, and `Step-read` relations and routes them to a dedicated `translate_step_reld` function. Rules with `RulePr` premises (bridge rules, evaluation-context rules) are automatically skipped. Each remaining rule generates a Maude equation of the form:

```maude
[c]eq step(< Z | LHS IS >) = < Z' | RHS IS > [if COND] .
```

### 4. Assoc-Variable Isolation

Maude's coherence checker can misfire when multiple equations for different operators share the same variable name as an associative "tail" pattern. All variable names in `wasm-exec.maude` carry unique per-group prefixes (`ST-*`, `AV-*`, `IV-*`, `IT-*`, `RL-*`, etc.) to prevent this class of interference.

### 5. Equational Reduction over CRL

All one-step behaviors are encoded as `eq`/`ceq` rather than `crl`. A single `crl [steps-trans]` drives the transitive closure. This ensures every atomic step fires during *equational normalization* of `step(EC)`, which is both faster and avoids the non-ground matching restrictions that would otherwise apply to rewrite rules.

---

## Documentation

| Document | Language | Audience |
|----------|----------|---------|
| [Translation_Rules.md](docs/Translation_Rules.md) | Korean | Advisors, lab researchers — formal translation rules for the current `translator.ml` |
| [execution_results.md](docs/execution_results.md) | Korean | How to run the translator/Maude smoke tests and read results |
| [maude_warning_analysis.md](docs/maude_warning_analysis.md) | Korean | Warning/advisory taxonomy, root causes, mitigation roadmap for `output.maude` and `wasm-exec.maude` |
| [experiment_repro.md](docs/experiment_repro.md) | Korean | Legacy split doc: reproduction-only procedure |

---

## License

Copyright © 2026 Minsung Lee (POSTECH SVLab). Licensed under the [MIT License](LICENSE).
