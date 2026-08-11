# Fibonacci model checking

This benchmark compiles the real `fib.wat` module to a Wasm binary. `wasm2maude`
decodes and validates that `.wasm`, encodes it as a SpecTec module term, and
emits the Maude instantiation, export invocation, and model-checking harness.

```sh
benchmarks/fibonacci/run.sh
```

All Wasm transitions use the generated `rel.step` relation from `output.maude`.
The checks cover rewriting, reachability of result `5`, unreachability of result
`6`, a true LTL property, and a false LTL property with a counterexample.
