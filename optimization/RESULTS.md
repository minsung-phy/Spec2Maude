# Fully materialized sort + context optimization result

Measured with Maude 3.5.1 on 2026-09-02.

## What was compared

- Program: recursive Fibonacci, input `fib(5)`.
- Expected result: `CONST(I64, 8)`.
- Rejected result for exhaustive bounded search: `CONST(I64, 6)`.
- Query: `search [1, 200]`.
- Baseline and optimized runs use the same Wasm module, wrapper, bound, and
  rejected-result predicate.

## Materialization checks

- `output_optimization.maude` loads without a Maude warning.
- It contains typed constructor, relation, definition, iteration, projector,
  and variable signatures rather than importing the old generated output.
- It contains no `Val < Instr`, `ValList < InstrList`, or
  `NeValList < NeInstrList` declaration.
- It contains no `to-instr-list` or `from-instr-list` compatibility adapter.
- `Step-pure(CONST(I64, 0) DROP)` rewrites to `instrNil`; this checks that a
  source `Val` pattern embedded in `InstrList` is active, not merely parsable.
- The inverse projector recovers `CONST(I64, 0)` from an `InstrList`.
- The focus smoke enumerates:

```text
PREFIX = CONST(I64, 0)
FOCUS  = CONST(I64, 1) CONST(I64, 2) BINOP(I64, ADD)
SUFFIX = NOP
```

- The public context step is atomic and produces:

```text
CONST(I64, 99) ; CONST(I64, 0) CONST(I64, 3) NOP
```

- The optimized Fibonacci query reaches the expected result at state 173
  after exploring 174 states and 56,234 rewrites.
- The rejected `CONST(I64, 6)` result is unreachable in both versions.

## Rejected-result benchmark

```text
                         baseline          sort + context
result                   No solution       No solution
states                   174               174
rewrites                  85,719,041        56,234
Maude CPU                 37.658s           0.150s
Maude real                37.782s           0.163s
process wall              37.86s            0.26s
```

Compared with the baseline:

- Rewrites decreased by 99.934% (`1,524x` fewer rewrites).
- Maude-reported real time improved by approximately `232x`.
- Both searches explored the same 174 public states.

## Commands

From `optimization/`:

```sh
maude -no-banner -no-advise semantics_optimization.maude
maude -no-banner -no-advise smoke_optimization.maude
maude -no-banner -no-advise fib_correctness_optimization.maude
/usr/bin/time -p maude -no-banner -no-advise fib_search_baseline.maude
/usr/bin/time -p maude -no-banner -no-advise fib_search_optimization.maude
```

## Scope

This is an experiment-only manual simulation of what the future annotated
translator should generate.  It does not modify the production translator.
The copied generator exists only to materialize a complete standalone result
for this measurement; the production implementation must later derive the same
sort/list and context lowering from the SpecTec IL and hints.
