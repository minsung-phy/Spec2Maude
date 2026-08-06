# SpaceWasm loader-state slice correspondence

The model-checked Wasm module `spacewasm-loader-slice.wat` is an executable
state projection of the exact SpaceWasm implementation pinned by the native
harness (`839feec79fcd7137e2e5f1a19922127f97d6d1d8`).  It contains no invented
failure mechanism: each state update below is a direct projection of one
production statement.

| Slice state/action | SpaceWasm production operation |
|---|---|
| `module-count` | `store.modules().len()` before a candidate module is appended |
| rejected attacker writes `table-module := module-count` | `Element::read` constructs `TableElement::Func { module: ModuleRef(store.modules().len() as u8), index }` and immediately executes `table[index] = tr` |
| rejected attacker leaves `module-count` unchanged | `Module::new` returns `Err`; the caller never invokes `Engine::push_module` |
| future load records current `module-count` and increments it | `Engine::push_module` appends the valid module and returns `ModuleRef((modules.len() - 1) as u8)` |
| provider indirect call follows `table-module` | `call_indirect` reads `TableElement::Func { module, index }`, then indexes `state.store.modules()[module]` and invokes that function |

The full native control runs those exact library functions against the exact
pinned NASA SpaceWasm source.  It establishes the abstraction relation used by
the model checker:

- without the rejected intermediate module, `provider.call` returns `7`;
- immediately after rejection, the dangling reference can crash
  `call_indirect` by indexing nonexistent module 1;
- after a later valid module is assigned module index 1, the same stale table
  reference invokes that module's private, non-exported function and returns
  `31337`.

The Maude model checker explores all six permutations of the three externally
observable events: rejected partial load, later valid load, and provider
indirect call.  Internal execution of `run3` is performed by the generated
SpecTec-derived WebAssembly semantics in `output.maude`; the production
`rel.step` relation is not modified.
