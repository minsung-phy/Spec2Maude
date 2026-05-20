<p align="center">
  <img src="https://img.shields.io/badge/SpecTec→Maude-C1%20Baseline-blue?style=for-the-badge" alt="SpecTec to Maude" />
</p>

<h1 align="center">Spec2Maude</h1>

<p align="center">
  <strong>A relation-preserving translator from WebAssembly 3.0 SpecTec semantics to Maude rewriting-logic specifications.</strong>
</p>

<p align="center">
  <a href="https://ocaml.org"><img src="https://img.shields.io/badge/OCaml-5.x-EC6813?logo=ocaml" alt="OCaml" /></a>
  <a href="https://maude.cs.illinois.edu"><img src="https://img.shields.io/badge/Maude-3.x-0066CC" alt="Maude" /></a>
</p>

---

## Overview

Spec2Maude is a research prototype for translating formal semantics written in
SpecTec into Maude.

The current active target is the **C1 baseline** for WebAssembly 3.0 SpecTec:

- preserve SpecTec relation/rule structure as directly as possible;
- avoid benchmark-specific execution hacks in the translator;
- generate executable Maude semantics useful for rewrite/search experiments;
- keep analysis-oriented transformations and model checking for a later C2
  phase.

The project is currently focused on making the generated `output_bs.maude` more
isomorphic to the original SpecTec, before returning to source-level initial
configuration and frontend work.

## Current Scope

This repository currently has two broad paths:

- **Active C1 path**:
  - `translator_bs.ml`
  - `output_bs.maude`
  - `wasm-exec-bs.maude`

- **Older / reference path**:
  - `translator.ml`
  - `output.maude`
  - `wasm-exec.maude`

Unless explicitly comparing with legacy behavior, use the active C1 path.

## Build and Regenerate

Build the C1 translator:

```bash
dune build ./main_bs.exe
```

Regenerate the C1 Maude output:

```bash
dune exec ./main_bs.exe -- wasm-3.0/*.spectec > output_bs.maude
```

Load the current Fibonacci regression harness:

```bash
maude wasm-exec-bs.maude
```

## Key Files

```text
Spec2Maude/
├── translator_bs.ml        # Active C1 translator
├── output_bs.maude         # Generated C1 Maude output; do not hand-edit as final
├── wasm-exec-bs.maude      # Current Fibonacci execution/regression harness
├── wasm-3.0/*.spectec      # WebAssembly 3.0 SpecTec sources
├── dsl/pretype.maude       # Shared Maude foundation modules
├── STATUS.md               # Current handoff and research state
├── README.md               # This file
├── translator.ml           # Older/reference translator path
├── output.maude            # Older/reference generated output
└── wasm-exec.maude         # Older/reference execution harness
```

## C1 Design Goal

C1 should preserve these SpecTec execution relations:

```spectec
relation Step      : config ~> config
relation Step_pure : instr* ~> instr*
relation Step_read : config ~> instr*
relation Steps     : config ~>* config
```

Generated Maude exposes wrappers of the form:

```maude
op step      : Config -> StepConf [frozen (1)] .
op step-pure : WasmTerminals -> StepPureConf [frozen (1)] .
op step-read : Config -> StepReadConf [frozen (1)] .
op steps     : Config -> StepsConf [frozen (1)] .
```

`steps` is intentionally unary:

```maude
steps(C) => C'
```

and configuration syntax uses:

```maude
_ ; _
```

## Current Successful Regressions

After regenerating `output_bs.maude`, load:

```maude
load wasm-exec-bs
```

### Expand function type

```maude
red in WASM-FIB-BS :
  $expanddt(value('TYPE, fib-funcinst)) .
```

Expected/current result:

```maude
CTORFUNCARROWA2(CTORI32A0 CTORI32A0 CTORI32A0, CTORI32A0)
```

### Invoke helper reduces to a concrete config

```maude
red in WASM-FIB-BS :
  $invoke(fib-store, 0, i32v(5) i32v(0) i32v(1)) .
```

Expected/current result: a concrete `Config`, not a stuck `$invoke(...)`.

### Focused one-step searches

The following focused cases should each have exactly one `Config` solution:

- `label(... br 0) local.get 1` suffix case;
- `const 1; br_if 0; local.get 1` suffix case;
- `nop; local.get 0` suffix case.

### Hand-assembled Fibonacci config

```maude
rew [10000] in WASM-FIB-BS :
  steps(fib-config(i32v(5))) .
```

Expected/current final result:

```maude
(fib-store ; empty-frame) ; CTORCONSTA2(CTORI32A0, 5)
```

## Known Non-Final Debt

### Label-related `step-from-step-pure-*` shortcuts

Most synthetic `step-from-step-pure-*` shortcuts have been removed. Only
label-related lifted shortcuts remain temporarily.

These rules are executable scaffolding, not C1-final relation-preserving output.
They remain because the strict single-rule version of `Step/ctxt-instrs` is
structurally faithful but Maude currently does not combine the required
associative split with the conditional rewrite premise for the label/br suffix
case.

Future work should either:

- find a faithful generic context-closure encoding for C1; or
- move execution-control scaffolding to C2.

### `fib-config-invoke` path

`$invoke(...)` reduces to a concrete config, but:

```maude
rew [10000] in WASM-FIB-BS :
  steps(fib-config-invoke(i32v(5))) .
```

currently stops early at a known outer invoke frame/label/block shape. Treat
this as a separate invoke-path issue, not as part of small cleanup tasks.

## Completed C1 Cleanup

Recent generator-side cleanups include:

1. **Singleton vs sequence variable naming**
   - `instr` becomes `INSTR`.
   - `instr*` becomes `INSTRS`.
   - `instr'` becomes `INSTRQ`.
   - `instr'*` becomes `INSTRSQ`.

2. **Boolean condition cleanup**
   - Generated conditions now use Maude Bool terms directly.
   - Redundant wrappers such as `(C =/= 0) = true` and `J(...) == valid = true`
     are removed from condition fragments.
   - Boolean definitions such as `eq $is-numtype(...) = true .` remain.

3. **Empty-result split cleanup**
   - Removed `step-pure-empty`.
   - Removed `step-read-empty`.
   - Removed `step-ctxt-instrs-empty`.
   - Removed `step-ctxt-label-empty`.
   - Removed `step-ctxt-handler-empty`.

4. **Non-label `step-from-step-pure-*` cleanup**
   - Non-label lifted shortcuts such as `step-from-step-pure-br-if-true` and
     `step-from-step-pure-nop` are suppressed.
   - Label-related variants remain as documented debt.

## Next Major Task: Validation Rule Lowering

Validation judgements such as `Module-ok`, `Func-ok`, `Instrs-ok`, `Instr-ok`,
and `Types-ok` are currently generated as:

```maude
eq  J(...) = valid .
ceq J(...) = valid if ... .
```

The professor requirement is that SpecTec `rule` / relation judgements should
be represented as Maude `rl/crl` as much as possible.

This requires a dependency-aware audit. Do not blindly replace `eq/ceq` with
`rl/crl`: caller premises currently use equation-style checks such as
`J(...) == valid`, and may need to become rewrite conditions such as
`J(...) => valid` if the callee is lowered as a rewrite rule.

Useful starting commands:

```bash
grep -nE "^(  )?(eq|ceq) (Module-ok|Func-ok|Instrs-ok|Instr-ok|Types-ok)" output_bs.maude | head -80
grep -n "use_rewrite_judgement" translator_bs.ml
grep -n "translate_reld" translator_bs.ml
grep -n "is_rewrite_judgement_rel" translator_bs.ml
```

## Source-Level Initial Configuration Goal

Current regressions still use a manually assembled Fibonacci harness. The
professor-facing path should eventually be:

```text
Wasm/WAT source
  -> Wasm module Maude term
  -> validation-preserving instantiate/invoke
  -> unary steps(Config)
  -> result
```

Immediate target after validation policy is clarified:

```text
fib-module Maude term
  -> Module-ok / instantiate
  -> invoke
  -> steps
  -> CTORCONSTA2(CTORI32A0, 5)
```

Do not add benchmark-specific shortcuts to `translator_bs.ml` to force this.

## Generic SpecTec Direction

The current implementation is still mostly a Wasm SpecTec translator. The longer
term goal is a more generic SpecTec-to-Maude translator.

Useful smoke test:

```bash
dune exec ./main_bs.exe -- p4-spectec/*/*.watsup > output_bs_p4.maude
```

Current status: P4 `.watsup` files mostly fail during parsing with syntax or
token errors. This shows a frontend/generic-SpecTec limitation, not a Maude
backend result yet.

## `WasmType` / Typecheck Infrastructure Audit

The old hand-written `dsl/pretype.maude` typecheck predicates `is-type`,
`are-types`, and `are-mixed` have been removed from the current C1 prelude
because generated `output_bs.maude` no longer uses them. The remaining
`WasmType` / `WasmTypes` substrate may still be overly broad and should be
audited separately.

This does **not** mean deleting Wasm type syntax such as `i32`, `functype`, or
`heaptype`, and it does **not** mean deleting validation semantics.

The audit should distinguish:

1. object-language type syntax;
2. validation relation semantics;
3. runtime/execution typecheck or membership guards.

If inputs are assumed well-typed, check whether execution rules still require
runtime typecheck/membership guards.

## What Not To Do In C1

Do not add any of the following to the active C1 translator:

- benchmark-specific rules;
- `mc`, `exec-step`, `focused-step`, or `dstep`;
- C2-style execution control;
- manual output-level patches as final solutions;
- validation bypasses;
- hardcoded Wasm judgement names in `translator_bs.ml`;
- Fibonacci-specific names in `translator_bs.ml`.

## Documentation Roadmap

Before claiming C1 is ready for professor review, prepare mapping evidence for:

- SpecTec syntax declarations -> Maude sorts/operators;
- SpecTec definitions -> Maude equations;
- SpecTec relation rules -> Maude `rl/crl` or documented current exception;
- `Step`, `Step_pure`, `Step_read`, and `Steps`;
- remaining non-C1-final debt.

Warning cleanup should be handled after the validation lowering audit, because
many used-before-bound warnings are tied to validation premise scheduling.

## License

Research prototype. Add or update repository license information as appropriate.
