# Spec2Maude Status

Updated: 2026-06-03

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
maude -no-banner output.maude                        PASS, no warnings
maude -no-banner wasm-exec.maude                     PASS, no warnings
./spec2maude validate wat_examples/fib.wat           PASS
rew [1] in WASM-FIB : steps(fib-config(i32v(5))) .   PASS
./spec2maude run wat_examples/fib.wat --fib 5        PASS
./spec2maude run wat_examples/data-load.wat          PASS
./spec2maude test smoke --timeout 10                 PASS: 13
```

Larger official/external benchmark tables should still be regenerated after
translator/runtime changes:

```bash
./spec2maude test official --limit 200 --timeout 10
./spec2maude test all --limit 500 --timeout 10
```

Bucket meanings:

- `PASS`: execution result matched the expected result.
- `STEPPED`: execution terminated, but no expected result was available.
- `INVALID`: input was rejected before runtime.
- `NO_ENTRY`: no exported/main entry was available to call.
- `IMPORT_MISSING`: required host import was not supplied.
- `UNSUPPORTED`: frontend/runner does not support the syntax yet.
- `STUCK_VALIDATION`: experimental Maude validation path stuck or timed out
  when that debug path is explicitly enabled.
- `STUCK_STEP`: dynamic execution stuck or timed out.
- `WRONG_RESULT`: execution terminated with a wrong observed result.

## Isomorphism State

Resolved:

- old `step-from-step-pure-*` bridge rules are gone;
- old `$is-spectec-val-seq` guard is gone;
- the JHS-style `SpectecType`/`typecheck` syntax carrier is restored;
- source syntax constructors are generated over the broad `SpectecTerminal`
  carrier instead of source category Maude sorts;
- source category validity is generated as `typecheck(term, category-term)`;
- syntax constructor cases also emit `mb`/`cmb` membership on
  `SpectecTerminal`;
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
2. Continue reducing source-absent helpers in `output.maude`.
3. Continue improving official `.wast` runner support for remaining vector and
   abstract reference result forms.  The runner now accepts the main GC
   reference families (`anyref`, `eqref`, `i31ref`, `structref`, `arrayref`,
   `exnref`) as invoke arguments and expected results.
4. Reduce remaining `STUCK_STEP` / `WRONG_RESULT` cases by instruction family.
5. Continue expanding proposal/module coverage where the official AST lowers
   successfully but the Maude runtime or harness still gets stuck.
6. Keep docs and CLI aligned with the default pipeline.
