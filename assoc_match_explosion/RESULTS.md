# Associative Context Lowering

Date: 2026-08-11

This directory records the unsorted baseline for `Step/ctxt-instrs`. It does
not add `Val`, `Vals`, `Instr`, or `Instrs` sorts.

## Source-Shaped Baseline

SpecTec embeds `val*` in an administrative instruction sequence. The two
representations are distinct in the generated Maude: for example, a source
number value is `num.const(...)`, while the corresponding runtime instruction
is `instr.const(...)`.

The generic `SubE` lowering therefore checks that the raw instruction prefix
is in the image of the source `val*` injection:

```maude
crl [step-ctxt-instrs] :
  rel.step(config.sym(Z, PATTERN1 (INSTR_STAR INSTR_1_STAR)))
  =>
  config.sym(Z_PRIME, PATTERN1 (INSTR_PRIME_STAR INSTR_1_STAR))
if
  VAL_STAR := helper.subtype-project-seq.step-pure(PATTERN1)
  /\ (VAL_STAR =/= eps or INSTR_1_STAR =/= eps)
  /\ rel.step(config.sym(Z, INSTR_STAR))
       => config.sym(Z_PRIME, INSTR_PRIME_STAR)
  /\ typecheck(config.sym(Z_PRIME, INSTR_PRIME_STAR), syn.config) .
```

`helper.subtype-project-seq.step-pure` is not a context splitter. It is the
source-derived partial inverse of the `val*`-to-`instr*` injection in the IL.
The rule reuses `PATTERN1` on the right-hand side, so it does not project and
then reinject the prefix.

The translator must not globally declare `instr.const` or `instr.vconst` to be
members of `syn.val`. Such equations would also admit instruction terms where
the source expects actual values, including frame locals.

## Removed Helpers

The former lowering emitted 17 `helper.context-*` operators that scanned an
instruction stream and chose a split. They were performance machinery rather
than a translation of a SpecTec or IL construct, and have been removed.

Unreachable helper families are removed independently by
`Generated_reachability.retain`. Helpers that remain implement a SpecTec
predefined operation or a source-derived lowering obligation such as `SubE`,
iteration, inverse matching, enabledness, or runtime truth.

## Fibonacci Check

The compiled-WAT Fibonacci benchmark completes over the regenerated root
`output.maude` and `builtins.maude`:

```text
rewrite to 5:          71,194 rewrites, 0.024 s CPU
search result 5:       71,207 rewrites, 0.022 s CPU, solution
search result 6:  239,390,691 rewrites, 93.796 s CPU, no solution
<> result 5:      239,390,722 rewrites, 93.806 s CPU, true
[] ~ result 6:    239,390,723 rewrites, 94.000 s CPU, true
<> result 6:           71,225 rewrites, 0.018 s CPU, counterexample
```

## Sort Experiment

A later experiment may replace the partial inverse with source-derived Maude
sorts for values and instruction sequences. That experiment must preserve the
same transitions and compare against this baseline without adding scanners,
fast execution rules, heating/cooling rules, or memoization.
