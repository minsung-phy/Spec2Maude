# Fibonacci semantic smoke test

This benchmark checks that freshly generated Maude semantics can rewrite,
search, and model check a small Fibonacci computation.

```sh
benchmarks/fibonacci/run.sh
```

The Maude file supplies a small hand-written initial configuration built only
from operators emitted by Spec2Maude.  It checks that `fib(5)` reaches `5`,
cannot reach `6`, eventually reaches `5`, and always avoids the incorrect
result `6`.  The final deliberately false liveness property must produce a
counterexample.

This is a semantics smoke test.  Translating `wat_examples/fib.wat` into its
initial Maude configuration is a separate frontend task.
