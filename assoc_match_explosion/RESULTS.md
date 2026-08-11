# Associative Context Lowering

Date: 2026-08-11

The translator now lowers `Step/ctxt-instrs` directly from its SpecTec shape.
This is the unsorted baseline for a later `Val`/`Instr` sort experiment.

## Generated Rule

The rule uses associative matching and the source `val*` membership:

```maude
crl [step-ctxt-instrs] :
  rel.step(config.sym(Z, VAL_STAR INSTR_STAR INSTR_1_STAR))
  =>
  config.sym(Z_PRIME, VAL_STAR INSTR_PRIME_STAR INSTR_1_STAR)
if
  typecheckSeq(VAL_STAR, syn.val) = true
  /\ (VAL_STAR =/= eps or INSTR_1_STAR =/= eps)
  /\ rel.step(config.sym(Z, INSTR_STAR))
       => config.sym(Z_PRIME, INSTR_PRIME_STAR)
  /\ typecheck(config.sym(Z_PRIME, INSTR_PRIME_STAR), syn.config) .
```

No `Val`, `Vals`, `Instr`, or `Instrs` sort is introduced here. Maude still
chooses the three associative fragments. `typecheckSeq` then accepts only a
`val*` prefix.

The source and instruction representations of constants use different
constructors. The translator derives the corresponding membership equations
from the existing subtype injection metadata:

```maude
ceq typecheck(instr.const(T, N), syn.val) = true
  if typecheck(num.const(T, N), syn.val) .

ceq typecheck(instr.vconst(T, V), syn.val) = true
  if typecheck(vec.vconst(T, V), syn.val) .
```

These equations preserve the source `val` membership on the emitted runtime
representation. They do not scan or split an instruction sequence.

## Removed Helpers

The old lowering emitted 17 `helper.context-*` operators that scanned the
instruction stream and selected a context. They were not present in SpecTec
and existed only to optimize matching, so they have been removed. The direct
rule also removes the projection/reinjection round trip:

```text
helper.subtype-project-seq.step-pure(PATTERN1)
helper.iter-map.step(VAL_STAR)
```

Other subtype, iteration, inverse, enabledness, and runtime-truth helpers are
unchanged. They lower source constructs that Maude cannot express directly.

## Fibonacci Result

The generated module and builtin module load without warnings. The compiled-WAT
Fibonacci benchmark completes with the direct rule:

```text
rewrite to 5:          72,468 rewrites, 0.024 s CPU
search result 5:       72,481 rewrites, 0.023 s CPU, solution
search result 6:  370,051,815 rewrites, 107.6 s CPU, no solution
<> result 5:      370,051,846 rewrites, 107.6 s CPU, true
[] ~ result 6:    370,051,847 rewrites, 107.5 s CPU, true
<> result 6:           72,499 rewrites, 0.023 s CPU, counterexample
```

The exhaustive checks are intentionally expensive in this unsorted baseline:
Maude still explores associative splits and rejects invalid prefixes through
membership. The next experiment may add source-derived sequence sorts, but it
must compare against this direct semantics without introducing a scanner or a
fast execution rule.
