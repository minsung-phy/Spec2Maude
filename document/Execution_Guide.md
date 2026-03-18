# Spec2Maude Execution Guide

## Overview

Spec2Maude translates the WebAssembly 3.0 SpecTec formal specification into a Maude algebraic specification. The generated module `SPECTEC-CORE` encodes Wasm's type system, arithmetic primitives, and small-step operational semantics as equational axioms.

This guide walks through building the translator, generating the Maude specification, running the equational test suite, and executing Wasm programs on the prototype stepping engine.

## Prerequisites

| Dependency | Version | Purpose |
|------------|---------|---------|
| OCaml | 5.x | Compiler for `translator.ml` |
| opam | 2.x | OCaml package manager |
| dune | 3.x | Build system |
| Maude | 3.x | Rewriting logic engine |

The project depends on the SpecTec libraries (`il`, `util`, `frontend`) which must be available as dune libraries. These are typically part of the [WebAssembly/spec](https://github.com/nicebyte/wasm-spec) repository's `spectec/` directory.

## Repository Structure

```
Spec2Maude/
├── main.ml                  # Entry point: parse → elaborate → translate
├── translator.ml            # Core translator (SpecTec IL → Maude)
├── dune                     # Build configuration
├── dsl/
│   └── pretype.maude        # Foundation Maude module (sorts, records)
├── output.maude             # Generated SPECTEC-CORE module
├── test/
│   ├── test-core.maude      # Equational unit tests (59 red commands)
│   └── wasm-exec.maude      # Executable stepping engine prototype
└── document/
    ├── Execution_Guide.md   # This file
    └── Translation_Rules.md # Formal translation rules
```

## Step 1: Build the Translator

```bash
cd Spec2Maude
dune build
```

This produces the executable `_build/default/main.exe`. Verify the build:

```bash
dune exec ./main.exe -- --help 2>&1 | head -1
# Usage: ./main.exe <file1.spectec> <file2.spectec> ...
```

## Step 2: Generate the Maude Specification

Feed the Wasm 3.0 SpecTec source files to the translator. The output is a single Maude module written to stdout:

```bash
dune exec ./main.exe -- \
  ../spectec/spec/wasm-3.0/*.watsup \
  > output.maude
```

The translator performs two passes over the elaborated AST:
1. **Pre-scan**: Collects bare tokens, call signatures, constructor names, and boolean-context functions.
2. **Translation**: Emits operator declarations, type-checking predicates (`is-type`), equational definitions (`eq`/`ceq`), and relation predicates (`Step-pure`, `Step-read`, etc.).

## Step 3: Verify the Specification Loads

```bash
maude output.maude <<< 'q'
```

The module should load without fatal errors. Advisory and ambiguity warnings related to duplicate constructor declarations are expected and semantically harmless (see [Translation Rules](Translation_Rules.md) for the confluence analysis).

## Step 4: Run Equational Unit Tests

The test suite validates 59 reductions across 8 categories:

```bash
maude test/test-core.maude
```

To extract just the results:

```bash
maude test/test-core.maude < /dev/null 2>&1 | grep "^result"
```

### Expected Results Summary

| Category | Tests | Examples |
|----------|-------|---------|
| Size/type primitives | 7 | `$size(I32) → 32` |
| Integer arithmetic | 10 | `$iadd(32, 3, 5) → 8`, `$binop(I32, ADD, 3, 5) → 8` |
| Comparison/test ops | 12 | `$ieqz(32, 0) → 1`, `$relop(I32, w-EQ, 42, 42) → 1` |
| Conversion helpers | 4 | `$signed(32, 2147483648) → -2147483648` |
| Aggregation | 5 | `$min(3, 5) → 3`, `$sum(eps) → 0` |
| Type-checking | 13 | `is-type(CONST I32 42, instr) → true` |
| Record operations | 4 | `value('FOO, {item('FOO, 42); ...}) → 42` |
| Step-pure predicates | 4 | `Step-pure(NOP, eps) → true` |

All 59 tests produce fully reduced, correct results.

## Step 5: Run the Executable Stepping Engine

The `WASM-EXEC` module wraps `SPECTEC-CORE` with rewrite rules, enabling `rew` (rewrite) commands to execute Wasm instruction sequences:

```bash
maude test/wasm-exec.maude
```

### Architecture

```
WASM-EXEC
├── Sorts: WI (wrapped instruction), WIS (instruction sequence), VS (value stack), Run (machine state)
├── Rewrite rules: const, nop, drop, unreachable, binop, testop, relop
└── Delegates arithmetic to SPECTEC-CORE's $binop, $testop, $relop
```

### Example: Computing Fibonacci(7) = 13

```maude
rew in WASM-EXEC :
  run(emptystack,
    wi(CONST I32 1)                            --- fib(2) = 1
    wi(CONST I32 1)  wi(BINOP I32 ADD)         --- 1 + 1 = 2 = fib(3)
    wi(CONST I32 1)  wi(BINOP I32 ADD)         --- 2 + 1 = 3 = fib(4)
    wi(CONST I32 2)  wi(BINOP I32 ADD)         --- 3 + 2 = 5 = fib(5)
    wi(CONST I32 3)  wi(BINOP I32 ADD)         --- 5 + 3 = 8 = fib(6)
    wi(CONST I32 5)  wi(BINOP I32 ADD)) .      --- 8 + 5 = 13 = fib(7)
```

**Output:**
```
rewrites: 387
result Run: halt(push(13, emptystack))
```

### Example: Expression Tree ((3+4) * (10-3)) = 49

```maude
rew in WASM-EXEC :
  run(emptystack,
    wi(CONST I32 3)  wi(CONST I32 4)  wi(BINOP I32 ADD)
    wi(CONST I32 10) wi(CONST I32 3)  wi(BINOP I32 SUB)
    wi(BINOP I32 MUL)) .
```

**Output:**
```
rewrites: 234
result Run: halt(push(49, emptystack))
```

### Example: Power of Two (2^10 = 1024)

```maude
rew in WASM-EXEC :
  run(emptystack,
    wi(CONST I32 1)
    wi(CONST I32 2)  wi(BINOP I32 MUL)
    wi(CONST I32 2)  wi(BINOP I32 MUL)
    --- ... (10 doublings)
    wi(CONST I32 2)  wi(BINOP I32 MUL)) .
```

**Output:**
```
rewrites: 772
result Run: halt(push(1024, emptystack))
```

## Understanding the Output

### Declarative vs. Executable Semantics

`SPECTEC-CORE` is a **formal specification**: it uses `eq`/`ceq` (equational axioms) to define predicates like `Step-pure(instrs, instrs') = true`. These are declarative assertions, not executable state transformers.

`WASM-EXEC` bridges this gap by wrapping the executable subset (arithmetic functions, type checks) in Maude rewrite rules (`rl`/`crl`), enabling `rew` commands.

### Ambiguity Warnings

Messages like `multiple distinct parses` appear because certain constants (e.g., `NOP`, `ADD`) have both `[ctor]` and non-`[ctor]` declarations. Maude arbitrarily selects one parse; both yield identical rewriting behavior. See [Translation Rules](Translation_Rules.md) for the formal confluence argument.
