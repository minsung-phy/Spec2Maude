# P4 / Generic SpecTec Readiness Notes

Updated: 2026-05-20

## Summary

The current C1 output is structurally complete for the WebAssembly 3.0 SpecTec
input, but the translator/prelude is not yet generic enough for a non-Wasm
SpecTec family such as `p4-spectec`.

The main issue is not missing Wasm coverage. It is that several generic roles
are still named or shaped as Wasm-specific infrastructure.

## Current P4 Blockers

1. Frontend/parser coverage

   Previous `p4-spectec` smoke attempts failed mostly in parsing/frontend
   stages with syntax errors, malformed tokens, or missing declarations after
   prerequisite files failed to parse. This blocks generic output before Maude
   generation becomes the main issue.

2. Carrier names are Wasm-specific

   Current generic carrier roles are named:

   - `WasmTerminal`
   - `WasmTerminals`
   - `WasmType`
   - `WasmTypes`

   For generic SpecTec, these should become names such as:

   - `SpecTecTerminal`
   - `SpecTecTerminals`
   - `SpecTecType`
   - `SpecTecTypes`

   or be parameterized per generated module.

3. Fixed Wasm index and parameter sorts

   The fixed header hardcodes:

   - `Labelidx`
   - `Localidx`
   - `Typeidx`
   - `Funcidx`
   - `Globalidx`
   - `Tableidx`
   - `Memidx`
   - `Tagidx`
   - `Elemidx`
   - `Dataidx`
   - `Fieldidx`
   - `Addr`
   - `Idx`
   - `N`, `M`, `K`

   These should be derived from parsed source syntax/category declarations
   rather than assumed.

4. Fixed Wasm type atoms

   The header declares:

   ```maude
   ops w-N w-M w-K w-n w-m w-X w-C w-I w-S w-T w-V w-b w-z w-L w-E : -> WasmType [ctor] .
   ```

   These are Wasm/Spectec-variable-shape assumptions. For P4, type/category
   atoms should be generated from the source or replaced by a generic variable
   witness scheme.

5. Fixed Wasm execution configuration model

   The header/footer currently assumes a Wasm execution shape:

   - `Store`
   - `Frame`
   - `State`
   - `Config`
   - `Store ; Frame`
   - `State ; instr*`
   - `step`, `step-pure`, `step-read`, `steps`

   P4 may have different judgement and configuration structure. Execution
   wrappers should be generated from source relation declarations, not fixed for
   Wasm.

6. Wasm-specific footer helpers

   Footer helpers that should not be part of a generic core include:

   - `$is-spectec-val-seq`, which is now generated from the source `val`
     category but should become a generic category-sequence predicate pattern
     for non-Wasm specs;
   - `$mk-frame`, tied to Wasm frame fields `LOCALS` and `MODULE`;
   - source-derived `$local` / `$with-local`, tied to `LOCALS` and still
     Wasm-specific even though their broad footer duplicates were removed;
   - specialized administrative constructor declarations for `LABEL`, `FRAME`,
     and `HANDLER`.

7. Non-C1-final execution debt

   The 20 label-related `step-from-step-pure-*` rules are not generic SpecTec
   translation. They are executable debt for the current Wasm C1 baseline and
   should become either:

   - a source-preserving generic bridge accepted into C1; or
   - C2 execution-layer infrastructure.

8. Benchmark harness separation

   `wasm-exec-bs.maude` contains Fibonacci-specific terms such as `fib-store`,
   `fib-config`, and `i32v`. This is acceptable as benchmark harness code, but
   it is not part of generic SpecTec-to-Maude translation.

## Pieces That Can Stay As Generic Prelude

These are good candidates for a reusable prelude after renaming/parameterizing
carrier names:

- sequence identity/concatenation:
  `eps`, `__`;
- sequence helpers:
  `len`, `index`, list update;
- record helpers:
  record items, `value`, record update, append/update;
- category witness machinery:
  `TypedTerm`, `WellTyped`, `_hasType_`;
- relation-result machinery:
  `Judgement`, `ValidJudgement`, `valid`;
- generated predicate namespace:
  `$is-spectec-*`;
- generic list type witness for `list(syntax X)`.

## Header/Footer Pieces To Parameterize Or Move

Parameterize:

- `WasmTerminal` / `WasmTerminals`;
- `WasmType` / `WasmTypes`;
- relation wrapper sorts such as `StepConf`;
- source relation wrapper operators;
- syntax/category predicate generation;
- source-derived constructor specialization.

Move out of strict generic core:

- benchmark harness;
- Wasm frame/store representation helpers;
- fixed Wasm value/category-sequence predicate names;
- list-lifting shortcuts if they are not source-derived;
- label-related `step-from-step-pure-*` debt.

Remove after ablation if unused:

- `DSL-EXEC` context module import/dependency;

Removed after focused ablation:

- `$cfg-state` / `$cfg-instrs`;
- `needs-label-ctxt`;
- `is-trap`;
- stale `VALOK-*` variables;
- disabled `ExecConf restore-*` translator branch.

## Suggested Genericization Plan

1. First remove dead header/footer artifacts with focused regression checks.
2. Rename or parameterize carrier sorts to neutral `SpecTec*` names.
3. Generate index/category numeric subsorts from source declarations rather than
   hardcoding Wasm names.
4. Move Wasm execution helpers into a Wasm-specific harness or generated
   extension layer.
5. Keep the strict C1 source translation free of benchmark terms.
6. Treat mode-aware execution helpers, witness synthesis, and context-closure
   adapters as C2 unless professor explicitly accepts them into C1.

## Current Recommendation

Use the Wasm C1 baseline as the structural reference, but do not present the
current header/footer as a generic SpecTec prelude yet. It is a mixed layer:
part generic prelude, part Wasm execution semantics, part executable harness,
and part legacy scaffolding.
