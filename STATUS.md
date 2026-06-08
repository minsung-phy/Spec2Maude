# Spec2Maude Status

Updated: 2026-06-08

## One-Line State

Spec2Maude has an active WebAssembly C1 baseline that translates the
WebAssembly SpecTec source to Maude and runs validated WAT/Wasm programs through
Maude dynamic execution.  The repository is now organized around the
professor-facing pipeline:

```text
.wat / .wasm
  -> official SpecTec/WebAssembly parser + validator
  -> Maude module term
  -> init/config harness
  -> steps(...)
```

The WAT/Wasm frontend now uses the official parser/validator from the SpecTec
repository (`vendor/wasm`).  WABT is still useful for `.wast` spec-test
extraction, but it is no longer the default `.wat`/`.wasm` validator.

The official-AST lowering path has been widened beyond the local toy examples:
it now lowers scalar/control/local/global/memory/table/ref instructions, and
also many SIMD, GC, array/struct, typed-reference, and exception-related AST
constructors.  This does not mean every WebAssembly 3.0 benchmark executes to a
correct result yet; the remaining failures are now more often runtime
execution, result comparison, import/WASI, or proposal edge cases.

## Active Components

```text
translator.ml       SpecTec-to-Maude translator
main.ml             translator CLI entry point
output.maude        generated WebAssembly Maude core
wasm_to_maude.ml       WAT/Wasm-to-Maude frontend
spec2maude.ml          reproducible top-level CLI
builtins.maude         Maude backend/builtin definitions
wasm-init.maude     init/config/runtime harness
wasm-exec.maude     direct execution smoke harness
wat_examples/          local smoke programs
scripts/               benchmark/smoke runner
```

Archived old path:

```text
legacy/old-baseline/
```

## Validation / Runtime Policy

The default execution path no longer treats generated `Module-ok` as the
runtime gate.

Current policy:

1. The official SpecTec/WebAssembly parser-validator rejects invalid `.wat` /
   `.wasm` before Maude.
2. The frontend emits a Maude module term for accepted input.
3. Maude runs initialization and dynamic execution with `steps(...)`.

The translated SpecTec validation relations still exist in the full generated
core because they are part of the source definition:

```text
Module-ok
Func-ok
Instr-ok
Instrs-ok
Reftype-sub
Heaptype-sub
...
```

But the default WAT/Wasm execution CLI does not use them as the input gate.
`maude-validate` remains an experimental/debug command.

## Latest Known Check Shape

The current JHS-carrier restoration should be judged first by syntax/load
checks, then by direct source-shaped execution.  Latest local checks:

```text
make build                                           PASS
./spec2maude translate -o output.maude               PASS
maude -no-banner output.maude                        PASS, warnings: 164, no-parse: 0
maude -no-banner wasm-exec.maude                     PASS, warnings: 177, no-parse: 0
./spec2maude validate wat_examples/fib.wat           PASS
rew [1] in WASM-FIB : steps(fib-config(i32v(5))) .   PASS
./spec2maude run wat_examples/fib.wat --fib 5        PASS
./spec2maude run wat_examples/data-load.wat          PASS
./spec2maude test smoke --timeout 10                 PASS: 13
./spec2maude test official --limit 30 --timeout 5    PASS: 45, MODULE_STAGE: 43, INVALID: 10,
                                                     STUCK_INIT: 13, STUCK_STEP: 67,
                                                     WRONG_RESULT: 3
```

The Maude warnings above are parser ambiguity warnings, not load failures.
They should still be reduced, but current load checks have zero errors, zero
bad tokens, and zero no-parse diagnostics.

Larger official/external benchmark tables should still be regenerated after
translator/runtime changes:

```bash
./spec2maude test official --limit 200 --timeout 10
./spec2maude test all --limit 500 --timeout 10
```

Bucket meanings:

- `PASS`: execution result matched the expected result.
- `MODULE_STAGE`: an official `.wast` command was module/linking/setup only and
  was not a runtime assertion to compare.
- `STEPPED`: execution terminated, but no expected result was available.
- `INVALID`: input was rejected before runtime.
- `NO_ENTRY`: no exported/main entry was available to call.
- `IMPORT_MISSING`: required host import was not supplied.
- `UNSUPPORTED`: frontend/runner does not support the syntax yet.
- `STUCK_INIT`: initialization, instantiation, or harness state setup stuck or
  timed out.
- `STUCK_VALIDATION`: experimental Maude validation path stuck or timed out
  when that debug path is explicitly enabled.
- `STUCK_STEP`: dynamic execution stuck or timed out.
- `WRONG_RESULT`: execution terminated with a wrong observed result.

## Isomorphism State

Resolved:

- old `step-from-step-pure-*` bridge rules are gone;
- old `$is-spectec-val-seq` guard is gone;
- the JHS-style `SpectecType`/`typecheck` syntax carrier is restored;
- source category/type witnesses are consistently generated as `syn-*`
  `SpectecType` terms, for example `syn-instr`, `syn-func`, and `syn-i32`;
- source syntax constructors are generated over the broad `SpectecTerminal`
  carrier instead of source category Maude sorts; their Maude surface names are
  source-readable lowercase constructors such as `const(i32, 5)` and
  `local-get(0)`;
- source category validity is generated as `typecheck(term, syn-category-term)`;
- syntax constructor cases also emit `mb`/`cmb` membership on
  `SpectecTerminal`;
- numeric literal payloads are raw Maude numerals again, classified through
  source-derived `typecheck(raw-number, syn-numeric-type)` equations;
- bulk source category sort/subsort generation is removed from the syntax path;
- generated WAT harnesses no longer include `Module-ok` checked-run code unless
  explicitly requested with the debug path.

Still worth discussing:

- `$infer-*` witness inference helpers;
- `$cont-*` continuation lowering for ordered `def` premises;
- mechanically generated lowering helpers for source meta-notation
  (`map`, ranges, optional/star forms, otherwise matching);
- which pieces belong in `output.maude` versus harness files.

## Immediate Next Work

1. Split translator profiles clearly:
   - full source profile: includes all SpecTec validation definitions;
   - runtime profile: excludes static validation from the runtime artifact or
     erases validation premises after external validation.
2. Continue reducing parser ambiguity warnings without changing source rule
   semantics.
3. Continue reducing source-absent helpers in `output.maude`.
4. Continue improving official `.wast` runner support for remaining vector,
   abstract-reference, and module instance/linking identity forms.  The runner
   now accepts the main GC reference families (`anyref`, `eqref`, `i31ref`,
   `structref`, `arrayref`, `exnref`) as invoke arguments and expected results.
5. Decide how to implement SpecTec `hint(builtin)` IEEE-float operations:
   Maude equations, a trusted numeric backend, or an explicit external oracle.
6. Reduce remaining `STUCK_INIT` / `STUCK_STEP` / `WRONG_RESULT` cases by
   instruction family.
7. Continue expanding proposal/module coverage where the official AST lowers
   successfully but the Maude runtime or harness still gets stuck.
8. Keep docs and CLI aligned with the default pipeline.
