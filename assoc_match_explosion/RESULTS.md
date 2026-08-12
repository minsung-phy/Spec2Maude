# Sorted sequence experiment

## Question

Does representing SpecTec `val`, `instr`, `val*`, and `instr*` with Maude
sorts reduce the associative matching cost of `Step/ctxt-instrs`?

This is a hand-written experiment.  It does not modify the translator or any
file outside this directory.

## Variants

`baseline/output.maude` is byte-for-byte identical to the root
`output.maude` used to start the experiment:

```text
25fe88471b92ed0af897581e9e16ff5ee1ebade5fefbf08725b5ae131e630a6c
```

`sorted/output.maude` adds the following sort refinement:

```maude
sorts Val Instr .
subsort Val < Instr .
subsort Instr < SpectecTerminal .

sorts EmptySeq Vals Instrs .
subsort EmptySeq < Vals .
subsort Vals < Instrs .
subsort Instrs < SpectecTerminals .
subsort Val < Vals .
subsort Instr < Instrs .

op eps : -> EmptySeq [ctor] .
op __ : Vals Vals -> Vals [ctor assoc id: eps] .
op __ : Instrs Instrs -> Instrs [ctor assoc id: eps] .
op __ : SpectecTerminals SpectecTerminals
  -> SpectecTerminals [ctor assoc id: eps] .
```

The experiment assigns the statically known result sorts of 106 instruction
constructors to `Instr`, eight reference constructors to `Val`, and `const`
and `vconst` to `Val`.  The existing `val <: instr` inclusion is represented
by `Val < Instr`.  No helper, memoization, heating/cooling rule, or new
transition was added.

The context rule becomes:

```maude
crl [step-ctxt-instrs] :
  rel.step(config.sym(
    Z,
    VAL_STAR:Vals
    INSTR_STAR:Instrs
    INSTR_1_STAR:Instrs))
  =>
  config.sym(
    Z_PRIME,
    VAL_STAR:Vals
    INSTR_PRIME_STAR:Instrs
    INSTR_1_STAR:Instrs)
if
  (VAL_STAR =/= eps or INSTR_1_STAR =/= eps)
  /\ rel.step(config.sym(Z, INSTR_STAR))
       => config.sym(Z_PRIME, INSTR_PRIME_STAR)
  /\ typecheck(
       config.sym(Z_PRIME, INSTR_PRIME_STAR),
       syn.config) .
```

`VAL_STAR:Vals` makes the former
`typecheckSeq(VAL_STAR, syn.val)` condition unnecessary.

The complete mechanical difference is in `sorted-output.patch`.

## Benchmark

`fib.wat` is the repository's compiled-Wasm Fibonacci benchmark.  It is
compiled to `fib.wasm`, converted to a SpecTec initial configuration by
`wasm2maude`, and executed using the selected copy of `output.maude` and
`builtins.maude`.

The harness runs:

1. bounded rewrite to completion;
2. positive search for result 5;
3. exhaustive negative search for result 6;
4. true LTL `<> returned(5)`;
5. true LTL `[] ~ returned(6)`;
6. false LTL `<> returned(6)` with a counterexample.

The following measurements are from one sequential, non-profiled run on
arm64 with Maude 3.5.1.  Rewrite counts are deterministic; millisecond timings
for the three fast queries are dominated by measurement noise.

| Query | Baseline rewrites | Sorted rewrites | Baseline real | Sorted real |
| --- | ---: | ---: | ---: | ---: |
| rewrite to result 5 | 89,657 | 88,501 | 29 ms | 41 ms |
| search result 5 | 89,669 | 88,513 | 29 ms | 35 ms |
| search result 6 (no solution) | 382,410,404 | 184,789,231 | 115.467 s | 94.999 s |
| LTL `<> returned(5)` | 382,410,433 | 184,789,260 | 116.307 s | 89.105 s |
| LTL `[] ~ returned(6)` | 382,410,434 | 184,789,261 | 119.265 s | 89.789 s |
| LTL `<> returned(6)` | 89,686 | 88,530 | 28 ms | 30 ms |

For the exhaustive negative search, sorted sequences reduce total rewrites by
197,621,173 (51.68%) and wall time by 17.73%, a 1.22x speedup.  The two true
LTL checks improve by about 1.31x and 1.33x respectively.

## Profile of `Step/ctxt-instrs`

Maude's profiler gives the following counts for the negative search:

| Metric | Baseline | Sorted | Change |
| --- | ---: | ---: | ---: |
| LHS matches | 25,456,850 | 14,571,667 | -42.76% |
| recursive `rel.step` tries | 7,285,615 | 7,285,615 | unchanged |
| successful context rewrites | 507,868 | 507,868 | unchanged |
| `typecheckSeq(VAL_STAR, syn.val)` tries | 18,170,798 | 0 | removed |

The unchanged recursive tries and successful rewrites are important: the sort
refinement preserves the explored transitions while rejecting invalid value
prefixes earlier.  The reduction is therefore caused by matching, not by a
shortcut in the Wasm semantics.

## Semantic checks

- Both generated modules load with no Maude warning, advisory, or error.
- Both variants return `const(i32, uN.wrap(5))`.
- The complete final rewrite results are byte-for-byte identical.
- Both variants find result 5 and reject result 6.
- Both variants return the same truth values and counterexample outcome for
  all three LTL checks.

## Conclusion

The proposed sort refinement works and materially reduces associative-match
exploration.  It removes about half of all rewrites in the exhaustive
Fibonacci checks, but only about one fifth to one quarter of wall time.  The
remaining cost is not evidence against the sort design: `INSTR_STAR` and
`INSTR_1_STAR` are both `Instrs`, so their associative split still has to be
explored, and the generated conditions outside this rule remain unchanged.

This result supports implementing source-derived `Val`/`Instr` and
`Vals`/`Instrs` sorts in the translator.  The translator implementation must
derive constructor sorts from SpecTec/IL declarations and inclusion edges;
the hand-written constructor list in this directory is only an experiment.

## Reproduction

```sh
cd assoc_match_explosion
./run.sh both
```

The full run takes several minutes.  Logs are written under `logs/`.
