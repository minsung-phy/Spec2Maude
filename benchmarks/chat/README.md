# Chat session-revocation model checking

The benchmark compiles `server.wat` to a Wasm binary. The Maude harness is
generated from that `.wasm`; it does not reimplement the server predicate.
`modelcheck.maude.in` models only the asynchronous delivery order of `LEAVE`
and a delayed `SEND`, which is outside Core Wasm.

The buggy export ignores the active-session flag, so the order `LEAVE; SEND`
accepts a revoked message.  The fixed export checks that flag.  Both handlers
are executed by the `rel.steps` relation generated from SpecTec.

```sh
benchmarks/chat/run.sh
```

Expected results:

- buggy reachability: solution;
- fixed reachability: no solution;
- buggy safety: counterexample;
- fixed safety: true;
- both variants eventually quiesce.
