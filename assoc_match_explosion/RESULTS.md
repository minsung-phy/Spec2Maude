# Associative Matching Sort Experiment

Date: 2026-08-11

This experiment changes files only under `assoc_match_explosion/`.
`translator/`, the root `output.maude`, the root `builtins.maude`, and the
existing benchmarks are not modified by the experiment.

## Inputs

- `output-baseline.maude`: the copied generated semantics before the experiment.
- `output.maude`: the hand-edited sort experiment.
- `fib.wat`: the same compiled-WAT Fibonacci benchmark used by the repository.
- `fib-baseline.maude` and `fib-sorted.maude`: identical generated initial
  configurations and properties, differing only in the loaded semantics.

The sorted version adds `Val`, `Instr`, `Vals`, and `Instrs`, classifies all
108 `instr.*` constructors as `Instr`, classifies the ten runtime value
instruction constructors as `Val`, and replaces the generated context splitter
in `step-ctxt-instrs` with a directly sorted associative pattern.

## Results

Both versions produce Fibonacci result 5, visit five model-checker states, reject
result 6, satisfy the two true LTL properties, and produce a counterexample for
the false LTL property.  Maude reports no warning or parse error.

| Check | Baseline rewrites | Baseline real | Sorted rewrites | Sorted real |
|---|---:|---:|---:|---:|
| Rewrite to result 5 | 59,529 | 29 ms | 65,778 | 29 ms |
| Search result 5 | 59,539 | 39 ms | 65,790 | 27 ms |
| Search: no result 6 | 116,057,377 | 59.171 s | 186,609,248 | 98.982 s |
| LTL: eventually result 5 | 116,057,408 | 61.108 s | 186,609,279 | 101.589 s |
| LTL: always not result 6 | 116,057,409 | 60.574 s | 186,609,280 | 101.651 s |
| LTL: eventually result 6 | 59,560 | 21 ms | 65,809 | 36 ms |

For the three checks that exhaust the reachable state space, the sorted version
performs about 60.8% more rewrites and takes about 67% more wall-clock time.

## Interpretation

The copied baseline is not the old naive three-way associative pattern.  It
already uses `helper.context-split.step`, which scans for the first non-value and
constructs context candidates explicitly.

The hand-edited sort version removes invalid value-prefix matches, but it still
contains two adjacent variables of the same sort:

```maude
INSTR_STAR:Instrs INSTR_1_STAR:Instrs
```

Therefore Maude must still try the possible boundaries between the executable
middle sequence and the suffix.  In addition, the generic `SpectecTerminals`
concatenation must coexist with the new `Vals` and `Instrs` overloads, and
partial instruction constructors require membership normalization before their
least sorts are available.

Consequently, adding these sorts locally does not improve the current generated
semantics.  A useful sorted design would need instruction sequences to retain
their precise sort throughout constructors, definitions, relations, and helper
results, without repeatedly falling back to the generic sequence carrier.  It
would also need a separate solution for the `instr*` / suffix boundary, because
both are `Instrs` and cannot be distinguished by sort alone.

