<h1 align="center">Spec2Maude</h1>

<p align="center">
  <strong>Translating SpecTec language definitions into executable Maude specifications.</strong>
</p>

---

## Overview

Spec2Maude is a research prototype for translating formal language
definitions written in **SpecTec** into **Maude** rewriting-logic
specifications.

The current case study is **WebAssembly 3.0**.  The goal is not just to produce
some hand-written Maude model of Wasm, but to study how much of a SpecTec
definition can be translated automatically while preserving the source
structure:

- SpecTec syntax declarations become Maude syntax/signature declarations.
- SpecTec `def` clauses become Maude `eq` / `ceq`.
- SpecTec `rule` clauses become Maude `rl` / `crl`.
- The generated Maude should stay close to the SpecTec source, but still be
  executable enough for concrete rewriting experiments.

This repository is therefore both:

1. a translator implementation, and
2. a research artifact for studying the boundary between strict source
   isomorphism and executable Maude infrastructure.

## Current Research Target

The active target is the **C1 WebAssembly baseline**.

C1 aims to preserve the source shape as much as possible while allowing a small
amount of source-derived execution infrastructure where Maude's execution model
does not directly match SpecTec notation.

Examples of current research questions:

- Can broad SpecTec sequence notation such as `val* instr* instr*` be represented
  cleanly in Maude without excessive category guards?
- Should witness-inference helpers such as `$infer-*` be allowed in the C1
  baseline?
- How much helper infrastructure is acceptable when making source-translated
  definitions executable?
- Can Wasm module initialization be driven through the source-translated
  `$instantiate` path rather than a hand-written runtime shortcut?

Detailed discussion notes live in:

```text
STATUS.md
docs/limitation.md
docs/HowToTest.md
```

## Repository Layout

```text
translator_bs.ml          active C1 SpecTec-to-Maude translator
main_bs.ml                C1 translator entry point
output_bs.maude           generated Maude output for WebAssembly SpecTec
builtins.maude            Maude implementations for selected builtin paths
wasm-init-bs.maude        runtime/init harness helpers kept outside output_bs.maude
wasm-exec-bs.maude        concrete execution harness and regression terms
wat_to_maude_fib.ml       focused WAT-to-Maude frontend for executable examples
examples/*.wat            WAT smoke-test inputs
wasm-3.0/*.spectec        WebAssembly 3.0 SpecTec source files
docs/HowToTest.md         current test commands
docs/limitation.md        current limitations and discussion points
STATUS.md                current handoff/status summary
```

Older files such as `translator.ml`, `output.maude`, and `wasm-exec.maude` are
legacy/reference paths unless explicitly stated otherwise.

## Build

Build the C1 translator and WAT frontend:

```bash
dune build ./main_bs.exe ./wat_to_maude_fib.exe
```

Regenerate the current WebAssembly Maude output:

```bash
dune exec ./main_bs.exe -- wasm-3.0/*.spectec > output_bs.maude
```

Load the execution harness:

```bash
maude wasm-exec-bs.maude
```

Expected load behavior: no Maude warning/advisory/error.

## Basic Execution

After loading `wasm-exec-bs.maude`, a direct Fibonacci smoke test is:

```maude
rew [1] in WASM-FIB-BS : steps(fib-config(i32v(5))) .
```

Expected final value:

```maude
CTORCONSTA2(CTORI32A0, 5)
```

The module-initialization path now goes through the source-translated
`$instantiate`:

```maude
red in WASM-FIB-BS : $instantiate(empty-store, fib-module, eps) .
rew [1] in WASM-FIB-BS : steps(fib-init-config(i32v(5))) .
```

## WAT Frontend

The repository includes a focused OCaml WAT frontend for executable examples.
It is not a full WebAssembly parser yet, but it supports the module features
and instructions needed by the current smoke tests.

Run Fibonacci from WAT:

```bash
dune exec ./wat_to_maude_fib.exe -- --result-only --run 5 examples/fib.wat
```

Expected output:

```text
result: CTORCONSTA2(CTORI32A0, 5)
```

Run selected module examples:

```bash
dune exec ./wat_to_maude_fib.exe -- --result-only --run-main examples/global-get.wat
dune exec ./wat_to_maude_fib.exe -- --result-only --run-main examples/memory-size.wat
dune exec ./wat_to_maude_fib.exe -- --result-only --run-main examples/table-size.wat
dune exec ./wat_to_maude_fib.exe -- --result-only --run-main examples/data-load.wat
dune exec ./wat_to_maude_fib.exe -- --result-only --run-main examples/elem-call-ref.wat
```

Run an import example:

```bash
dune exec ./wat_to_maude_fib.exe -- --result-only \
  --run-export main \
  --arg-i32 41 \
  --import-func 'env.bump=local.get 0 i32.const 1 i32.add' \
  examples/import-func.wat
```

Expected output:

```text
result: CTORCONSTA2(CTORI32A0, 42)
```

More complete test commands are documented in [docs/HowToTest.md](docs/HowToTest.md).

## Current Scope

Current generated C1 coverage structurally covers the WebAssembly 3.0 SpecTec
input used in this repository:

```text
source files:              21 / 21
syntax declarations:       249 / 249
def declarations:          1272 / 1272
relation declarations:     82 / 82
rule declarations:         499 / 499
```

The runtime path is intentionally narrower than full WebAssembly.  The focused
WAT frontend currently covers representative examples involving:

- integer arithmetic and control flow,
- globals,
- memories and active data segments,
- tables and active element segments,
- direct calls and `call_ref`,
- start functions,
- selected function/global/memory/table imports.

## Limitations

This is still a research prototype, not a production Wasm runtime.

Known limitations include:

- the WAT frontend is focused, not a complete WAT parser;
- not every WebAssembly instruction family is implemented in the executable
  smoke path;
- some source-derived helper rules remain in the generated output to make broad
  SpecTec sequences and record updates executable in Maude;
- the exact boundary of acceptable helper infrastructure is still a research
  question for the C1 baseline.

See [docs/limitation.md](docs/limitation.md) for the current detailed
discussion.

## Development Notes

`output_bs.maude` is generated.  Prefer changing `translator_bs.ml` and
regenerating rather than hand-editing `output_bs.maude`.

Use `docs/HowToTest.md` before committing changes that affect translation or
execution.
