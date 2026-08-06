# SpaceWasm loader-state projection correspondence

The model-checked Wasm module `spacewasm-loader-slice.wat` is an executable,
property-directed state projection of the exact SpaceWasm implementation pinned
by the native harness (`839feec79fcd7137e2e5f1a19922127f97d6d1d8`).
Each projected state update corresponds to a production operation; exact
six-schedule native replays validate the resulting outcome classification.

| Projected state/action | SpaceWasm production operation |
|---|---|
| `module-count` | `store.modules().len()` before a candidate module is appended |
| rejected attacker writes `table-module := module-count` | `Element::read` constructs `TableElement::Func { module: ModuleRef(store.modules().len() as u8), index }` and immediately executes `table[index] = tr` |
| rejected attacker leaves `module-count` unchanged | `Module::new` returns `Err`; the caller never invokes `Engine::push_module` |
| future load records current `module-count` and increments it | `Engine::push_module` appends the valid module and returns `ModuleRef((modules.len() - 1) as u8)` |
| provider indirect call follows `table-module` | `call_indirect` reads `TableElement::Func { module, index }`, indexes `state.store.modules()[module]`, and invokes that function |
| `table-module >= module-count` yields outcome 2 | the production `call_indirect` indexes a nonexistent module and panics at `src/interpreter.rs:1485` |
| a completed provider call sets `table-shared` | the engine state retains another `Rc` reference to the provider's table |
| attacker load with `table-shared` yields outcome 3 | `Module::get_table` executes `table.get_mut().unwrap()`; `Rc::get_mut` returns `None` and production panics at `src/module.rs:862` |
| stale `table-module == future-module` yields outcome 1 | module-index reuse makes the rejected candidate's stale reference invoke the future module's function 0 |

The projection returns one of four observable outcomes:

```text
0 = no bad call observed in the bounded trace
1 = future private function executed through stale-reference resurrection
2 = dangling module index followed by call_indirect
3 = shared imported-table mutation panic
```

The exact native controls run the real pinned library functions, not this
projection.  They establish:

- `attack -> future -> call` returns the future module's private value `31337`;
- `attack -> call -> future` and `future -> attack -> call` panic by following
  nonexistent module indices;
- schedules where a provider call precedes the imported-table element write
  panic because the table is no longer uniquely owned;
- the remaining output classification is identical to the projection.

The Maude model checker explores all six permutations of the three externally
observable events: rejected partial load, later valid load, and provider
indirect call. Internal execution of `run3` is performed by the generated
SpecTec-derived WebAssembly semantics in `output.maude`; the production
`rel.step` relation is not modified.
