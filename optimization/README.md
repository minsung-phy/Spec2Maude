# Fully materialized sort + context optimization experiment

This directory tests the agreed optimization before changing the production
translator.  `output_optimization.maude` is a complete generated Maude module,
not a wrapper around the old untyped output.  It is produced by the
experiment-only generator in `manual_generator/` from the 21 Wasm SpecTec
files.

The materialized policy is:

1. Scalar sorts `Num`, `Vec`, `Ref`, `Val`, and `Instr`.
2. `Num Vec Ref < Val` and `Num Vec Ref < Instr`, but never `Val < Instr`.
3. Independent Prelude instances `ValList`, `InstrList`, and `RefList`, with no
   list-level subsort edges.
4. Common Prelude lists for all other sequence types; nested typed lists are
   carried by explicit `valSeq`, `instrSeq`, and `refSeq` elements.
5. Partial inverse helpers connect a `Val` pattern with an `InstrList` pattern
   without adding the forbidden `Val < Instr` edge.
6. The original associative `Step/ctxt-instrs` rule is replaced by relational
   focus enumeration, heating, private direct firing, equational cooling, and
   one atomic public context transition.

Active files:

- `output_optimization.maude`: fully materialized 10,486-line generated result.
- `manual_generator/`: experiment-only source used to materialize that result.
- `support/`: experiment-local Prelude-based support modules.
- `relation-backends.maude`, `builtins.maude`: experiment-local runtime support.
- `semantics_optimization.maude`: loader for the optimized semantics.
- `smoke_optimization.maude`: typed direct-rule, projector, focus, and atomic
  context-transition checks.
- `fib_search_baseline.maude`: rejected `fib(5)=6` baseline query.
- `fib_search_optimization.maude`: the identical optimized query.
- `fib_correctness_optimization.maude`: expected `fib(5)=8` query.
- `RESULTS.md`: commands and measured results.

Regenerate from the repository root:

```sh
dune build optimization/manual_generator/spec2maude_manual.exe
dune exec optimization/manual_generator/spec2maude_manual.exe
```

Run verification from `optimization/`:

```sh
maude -no-banner -no-advise semantics_optimization.maude
maude -no-banner -no-advise smoke_optimization.maude
maude -no-banner -no-advise fib_correctness_optimization.maude
/usr/bin/time -p maude -no-banner -no-advise fib_search_optimization.maude
```

The `sort/`, `focus/`, and `sort_focus/` directories are superseded exploratory
work.  They are not loaded by the final combined experiment.
