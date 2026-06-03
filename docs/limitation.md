# Current Limitations And Discussion Points

Updated: 2026-06-03

This document records the current state after restoring the JHS-style
`SpectecType`/`typecheck` syntax layer and adding Maude constructor membership
axioms.

## 1. Parser / Validator

Current implementation:

```text
.wat / .wasm -> official SpecTec/WebAssembly parser + validator -> Wasm AST
            -> Maude term
```

WABT is no longer the default `.wat` / `.wasm` validator.  It may still be used
by benchmark scripts to expand official `.wast` tests into JSON.

## 2. Syntax Encoding Status

The generated syntax layer now follows AST-driven JHS carrier patterns:

```text
category/type name           constructor term of sort SpectecType
source syntax constructor    broad constructor returning SpectecTerminal
category check               eq/ceq typecheck(pattern, category-term) = true
constructor membership       mb/cmb pattern : SpectecTerminal
category alias/inclusion     delegated typecheck equation
```

The generated syntax layer should not contain:

```text
SpectecCategory
WasmType
hasType / WellTyped / _hasType_
SortCTOR...
bulk source category sorts such as sort Instr, sort Valtype, sort Typeuse
source category subsorts such as subsort Instr < SpectecTerminal
broad numeric subsorts such as Nat < U32 or Int < IN32
```

Numeric literal families are represented as raw Maude numerals carried by
`SpectecTerminal`:

```text
i32.const 5 -> CTORCONSTA2(CTORI32A0, 5)
i64.const 5 -> CTORCONSTA2(CTORI64A0, 5)
```

This follows the JHS carrier shape: `Nat`/`Int` are terminals, and generated
`typecheck(raw-number, source-type)` equations classify source numeric
categories such as `uN(32)`, `sN(33)`, and `byte`.

## 3. What Changed Beyond Syntax

The source `relation`, `rule`, and `def` declarations are still translated
from the SpecTec AST; the rewrite did not intentionally replace the Step,
Step_pure, Step_read, or Steps semantics with a different execution strategy.
In particular, `Steps` is generated as the source-shaped recursive
reflexive-transitive closure.

The context-lifting `Step/ctxt-instrs` rule is emitted as the source-shaped
rule itself.  The translator does not add a separate `$run-*` fuel runner or a
non-context `Step` helper for this path.  Redundant iterator-empty variants are
not emitted for these execution rules; sequence variables already range over
`eps`, so the source rule plus its source non-empty condition covers those
cases.

The literal representation is raw again.  Generated runtime equations and
rules that compute over numeric payloads still need representation-boundary
plumbing:

```text
project raw terminal to Maude builtin number -> compute -> preserve raw result
```

This plumbing is not a source category predicate and is not a replacement for
the generated `typecheck`/`mb`/`cmb` syntax layer.  It exists only because
numeric operations still compute over Maude builtin integers internally.

## 4. Module-ok Is Not The Default Gate

The full generated core still contains SpecTec validation relations because
they are part of the source:

```text
Module-ok
Func-ok
Instr-ok
Instrs-ok
...
```

But the default WAT/Wasm frontend path does not use translated `Module-ok` to
decide whether execution may start.  Invalid programs are rejected before Maude
execution by the official SpecTec/WebAssembly validator.

Open point:

```text
Should the paper artifact keep full source validation in output.maude, or
should we produce a separate runtime-only profile after external validation?
```

## 5. Runtime Profile Split Is Not Finished

A clean final structure should probably provide two artifacts:

```text
output_full_bs.maude      full SpecTec translation, including validation
output_runtime_bs.maude   dynamic runtime profile after external validation
```

This is not fully implemented yet.  A naive removal of validation files fails
because `4.4-execution.modules.spectec` contains `$instantiate` premises that
refer to `Module_ok`.

Therefore the next cleanup must be explicit:

1. keep a full source-isomorphic profile for audit;
2. derive a runtime profile that erases or externalizes static validation
   premises only after the input has been validated.

## 6. Remaining Non-Isomorphic Machinery

The main remaining source-absent mechanisms are:

```text
$infer-*       witness inference for relation premises
$cont-*        continuation lowering for ordered def premises
meta-notation lowering helpers for star/optional/map/range/otherwise forms
$raw-lit       representation-boundary numeric projection
$wrap-lit      representation-boundary numeric result preservation
```

These are not benchmark-specific hardcoding, but they are still not literally
present in the SpecTec source.  They should be justified as systematic lowering
or moved into a clearly named execution-support layer.

## 7. WAT/Wasm Frontend Coverage

The frontend supports the current local smoke suite through the official AST
path and part of the official test corpus.  The lowering path now covers more
than the original focused subset, including many SIMD/GC/array/struct/exception
AST constructors.

Known gaps include:

- IEEE-754 float builtin semantics (`$fadd`, `$fsub`, `$fmul`, `$fdiv`,
  conversions, NaN propagation, rounding-sensitive cases).  The SpecTec source
  marks these definitions as `hint(builtin)`, so a source-isomorphic
  translator can expose the operations but still needs a backend/oracle to
  compute them;
- full benchmark-scale execution for exception/tag, GC, and SIMD-heavy cases;
- richer vector expected-result comparison and more precise abstract-reference
  result matching in the `.wast` runner;
- richer WASI/import linking, especially official `.wast`
  `module_definition`/`module_instance` identity and shared exported
  global/table/tag aliases;
- more precise failure classification for real-world benchmarks.

## 8. Benchmark Status

The local smoke suite currently passes through the default frontend/runtime
path:

```bash
./spec2maude test smoke --timeout 10
```

Most recent local check shape after the JHS-carrier restoration and constructor
membership generation:

```text
make build                                           PASS
./spec2maude translate -o output.maude               PASS
maude -no-banner output.maude                        PASS, no warnings
maude -no-banner wasm-exec.maude                     PASS, no warnings
./spec2maude validate wat_examples/fib.wat           PASS
rew [1] in WASM-FIB : steps(fib-config(i32v(5))) .   PASS
./spec2maude run wat_examples/fib.wat --fib 5        PASS
./spec2maude run wat_examples/data-load.wat          PASS
./spec2maude test smoke --timeout 10                 PASS: 13
```

Larger official/external benchmark numbers should be regenerated after each
frontend or translator change because the status buckets are sensitive to the
chosen pipeline.

Important interpretation:

- `STUCK_VALIDATION` belongs only to the experimental Maude validation path.
- `STUCK_STEP` and `WRONG_RESULT` are the more important runtime execution gaps
  for the default architecture.

## 9. What To Say In A Meeting

Short version:

```text
The syntax layer is back to the JHS carrier shape: SpecTec categories are
SpectecType terms, constructors return SpectecTerminal, category validity is
represented by typecheck, and constructor existence also emits Maude mb/cmb
membership on SpectecTerminal.  Numeric literals use explicit object-level
raw Maude numerals, while source numeric categories are classified by
generated typecheck equations.  The Step/Step_pure/Step_read/Steps relations
are still generated from the SpecTec source; numeric boundary helpers are
representation plumbing, not a semantic replacement.
```

Open question:

```text
Should the final artifact ship both a full SpecTec translation and a smaller
runtime-only profile, or should output.maude always remain the full source
translation?
```
