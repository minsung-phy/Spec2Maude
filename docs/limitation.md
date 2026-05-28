# Current Limitations And Discussion Points

Updated: 2026-05-29

This document records the current limitations after aligning the project with
the professor-facing architecture:

```text
validated WAT/Wasm input
  -> Maude module term
  -> Maude dynamic execution
```

## 1. Parser / Validator

Current implementation:

```text
.wat / .wasm -> official SpecTec/WebAssembly parser + validator -> Wasm AST
            -> Maude term
```

WABT is no longer the default `.wat` / `.wasm` validator.  It may still be used
by benchmark scripts to expand official `.wast` tests into JSON.

## 2. Module-ok Is Not The Default Gate

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
Should the paper artifact keep full source validation in output_bs.maude, or
should we produce a separate runtime-only profile after external validation?
```

## 3. Runtime Profile Split Is Not Finished

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

## 4. Remaining Non-Isomorphic Machinery

The main remaining source-absent mechanisms are:

```text
$infer-*       witness inference for relation premises
$cont-*        continuation lowering for ordered def premises
meta-notation lowering helpers for star/optional/map/range/otherwise forms
```

These are not benchmark-specific hardcoding, but they are still not literally
present in the SpecTec source.  They should be either justified as systematic
lowering or moved into a clearly named execution-support layer.

## 5. WAT/Wasm Frontend Coverage

The frontend supports the current local smoke suite through the official AST
path and part of the official test corpus.  The lowering path now covers more
than the original focused subset, including many SIMD/GC/array/struct/exception
AST constructors.

Known gaps include:

- full benchmark-scale execution for exception/tag, GC, and SIMD-heavy cases;
- richer vector expected-result comparison and more precise abstract-reference
  result matching in the `.wast` runner;
- richer WASI/import linking;
- more precise failure classification for real-world benchmarks.

## 6. Benchmark Status

The local smoke suite currently passes through the default frontend/runtime
path.  Larger official/external benchmark numbers should be regenerated after
each frontend or translator change because the status buckets are sensitive to
the chosen pipeline.

Important interpretation:

- `STUCK_VALIDATION` belongs only to the experimental Maude validation path.
- `STUCK_STEP` and `WRONG_RESULT` are the more important runtime execution gaps
  for the default architecture.

## 7. What To Say In A Meeting

Short version:

```text
I separated the default runtime story from Maude-internal Module-ok checking.
The default path now validates WAT/Wasm before Maude, converts the validated
program into a Maude module term, and runs the dynamic semantics.  The full
SpecTec validation relations are still generated for source coverage/debug, but
they are no longer presented as the main execution gate.
```

Open question:

```text
Should the final artifact ship both a full SpecTec translation and a smaller
runtime-only profile, or should output_bs.maude always remain the full source
translation?
```
