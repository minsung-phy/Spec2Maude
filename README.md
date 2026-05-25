<p align="center">
  <img src="https://img.shields.io/badge/SpecTec→Maude-C1%20Baseline-blue?style=for-the-badge" alt="SpecTec to Maude" />
</p>

<h1 align="center">Spec2Maude</h1>

<p align="center">
  <strong>A relation-preserving translator from WebAssembly 3.0 SpecTec semantics to Maude rewriting-logic specifications.</strong>
</p>

---

## Overview

Spec2Maude is a research prototype for translating formal semantics written in
SpecTec into Maude.

The active target is the **C1 WebAssembly baseline**:

- preserve SpecTec syntax / def / rule structure and intent;
- lower SpecTec `def` to Maude `eq/ceq`;
- lower SpecTec `rule` to Maude `rl/crl`;
- keep unconditional source rules unconditional and conditional source rules
  conditional;
- avoid benchmark-specific translator hacks;
- make the generated baseline executable enough for concrete rewrite/search
  experiments.

The current C1 direction is best described as **source-structured executable
isomorphism**: the source structure remains primary, but a small number of
source-derived helpers are still needed because Maude executes broad associative
sequences differently from SpecTec notation.

## Active Files

Use the C1 path unless explicitly comparing with older code:

```text
translator_bs.ml        active C1 translator
output_bs.maude         generated C1 output; do not hand-edit as final
builtins.maude          backend implementations for current hint(builtin) paths
wasm-init-bs.maude      focused init/config harness kept outside output_bs.maude
wasm-exec-bs.maude      concrete Fibonacci / reference execution harness
examples/*.wat          focused WAT frontend/runtime smoke inputs
wat_to_maude_fib.ml     focused OCaml WAT-to-Maude frontend
wasm-3.0/*.spectec      WebAssembly 3.0 SpecTec sources
STATUS.md              current handoff summary
docs/limitation.md      current limitation / professor-discussion document
docs/HowToTest.md       current smoke-test commands
```

Older files such as `translator.ml`, `output.maude`, and `wasm-exec.maude` are
reference/legacy paths.

## Build And Regenerate

```bash
dune build ./main_bs.exe
dune exec ./main_bs.exe -- wasm-3.0/*.spectec > output_bs.maude
```

Load the execution harness:

```bash
maude wasm-exec-bs.maude
```

`wasm-exec-bs.maude` loads `wasm-init-bs.maude`; that loads `builtins.maude`,
which loads `output_bs.maude`.

Generate the focused Fibonacci WAT harness:

```bash
dune exec ./wat_to_maude_fib.exe -- examples/fib.wat > /tmp/fib.generated.maude
maude /tmp/fib.generated.maude
```

Or generate and run in one CLI step:

```bash
dune exec ./wat_to_maude_fib.exe -- --run 5 examples/fib.wat
dune exec ./wat_to_maude_fib.exe -- --result-only --run-export wrapper --arg-i32 5 examples/fib-wrapper.wat
```

The frontend is an OCaml focused WAT frontend. It now emits Maude terms for
types, imports, globals, memories, tables, local functions, data segments,
element segments, start, and exports, plus the integer/control/runtime
instructions used by the current examples. It is still not a full WAT parser.

Additional focused runtime smokes:

```bash
dune exec ./wat_to_maude_fib.exe -- --run-main examples/global-get.wat
dune exec ./wat_to_maude_fib.exe -- --run-main examples/memory-size.wat
dune exec ./wat_to_maude_fib.exe -- --run-main examples/table-size.wat
dune exec ./wat_to_maude_fib.exe -- --run-main examples/start-global.wat
dune exec ./wat_to_maude_fib.exe -- --run-main examples/data-load.wat
dune exec ./wat_to_maude_fib.exe -- --run-main examples/elem-call-ref.wat
```

Imports are linked automatically for the focused runtime path:

```bash
dune exec ./wat_to_maude_fib.exe -- --result-only --run-export main --arg-i32 41 \
  --import-func 'env.bump=local.get 0 i32.const 1 i32.add' \
  examples/import-func.wat
dune exec ./wat_to_maude_fib.exe -- --result-only --run-export main \
  --import-global 'env.g=i32.const 77' examples/import-global.wat
dune exec ./wat_to_maude_fib.exe -- --result-only --run-export main examples/import-memory.wat
dune exec ./wat_to_maude_fib.exe -- --result-only --run-export main examples/import-table.wat
```

Active data and element initialization are covered through the source-translated
`$instantiate` path, with source-derived memory/table/elem helper bridges used
where Maude execution would otherwise get stuck on broad sequence/record update
patterns.

## Current Structural State

Current generated C1 coverage:

```text
WebAssembly SpecTec source files: 21 / 21
syntax declarations:             249 / 249
def declarations/equations:       1272 / 1272
relation declarations:            82 / 82
rule declarations:                499 / 499
strict validation rule targets:   281 / 281 primary rl/crl
missing source constructs:        0 known
eq/ceq ... = valid:               0
iter-empty / opt-empty labels:    0
```

Generated execution wrappers include:

```maude
op step      : Config -> StepConf [frozen (1)] .
op step-pure : SpectecTerminals -> StepPureConf [frozen (1)] .
op step-read : Config -> StepReadConf [frozen (1)] .
op steps     : Config -> StepsConf .
```

`steps` is unary:

```maude
steps(C) => C'
```

## Current Professor-Discussion Items

### 1. Category / Sequence Gap + Generic Step-Pure Bridge

SpecTec source has sequence categories such as:

```spectec
rule Step/ctxt-instrs:
  z; val* instr* instr_1*  ~>  z'; val* instr'* instr_1*
  -- Step: z; instr* ~> z'; instr'*
  -- if val* =/= eps \/ instr_1* =/= eps
```

Current C1 still represents most sequences with one broad carrier:

```maude
SpectecTerminals
op __ : SpectecTerminals SpectecTerminals -> SpectecTerminals [assoc id: eps] .
```

Therefore `val* instr* instr_1*` cannot yet be represented entirely by distinct
Maude sequence sorts. The current generated rule keeps the source structure and
adds a minimal value-prefix shape guard:

```maude
crl [step-ctxt-instrs] :
  step((Z ; VALS INSTRS INSTRS1))
  =>
  (ZQ ; VALS INSTRSQ INSTRS1)
  if $is-spectec-val-seq(VALS)
  /\ (VALS =/= eps \/ INSTRS1 =/= eps)
  /\ step((Z ; INSTRS)) => (ZQ ; INSTRSQ) .
```

For pure steps under the same context shape, the output also contains one
generic bridge:

```maude
crl [step-from-step-pure-ctxt-instrs] :
  step((Z ; VALS INSTRS INSTRS1))
  =>
  (Z ; VALS INSTRSQ INSTRS1)
  if $is-spectec-val-seq(VALS)
  /\ (VALS =/= eps \/ INSTRS1 =/= eps)
  /\ step-pure(INSTRS) => INSTRSQ .
```

This bridge is not a literal source rule. It is source-derived from
`Step_pure` under the `Step/ctxt-instrs` context shape, and exists because the
otherwise strict path must search through broad associative sequence splits.

The output also has a small zero-local function-call bridge for `call_ref`.
It covers the source-valid case where a function has `local* = eps`; the
literal generated rule currently misses that case because one mapped-local
intermediate is inferred with a too-narrow sort.

### 2. `$infer-*` Witness Inference Overlay

Some source relation premises introduce intermediate witnesses that later
premises use. For example, `Instrs_ok/seq` needs the intermediate `t_2*` from
the first `Instr_ok` premise before checking the rest of the sequence.

The current relation encoding is judgement-style:

```maude
Instr-ok(...) => valid
```

That form proves validity but does not directly return witness arguments. The
translator therefore generates source-premise-derived helpers such as:

```maude
$infer-instr-ok-arg2(C, INSTR1) => ARROW(TS1, XS1, TS2)
```

These helpers are not benchmark hardcoding, but they are source-absent
execution overlay and should be accepted or rejected explicitly for C1.

## Typecheck / Category Cleanup

Under the well-typed-input assumption, runtime no longer needs most generated
category/typecheck infrastructure.

Current generated `output_bs.maude`:

- does not contain `SPECTEC-CATEGORIES`;
- does not contain generated `mb/cmb` category axioms;
- does not contain `hasType` / `WellTyped`;
- does not contain general `$is-spectec-*` category predicates;
- keeps only `$is-spectec-val` and `$is-spectec-val-seq` as runtime
  sequence-shape infrastructure for `val*` prefixes.

This does **not** delete Wasm type syntax such as `i32`, `functype`, `reftype`,
or `heaptype`, and it does **not** delete SpecTec validation relations such as
`Instr-ok`, `Instrs-ok`, `Module-ok`, `Reftype-sub`, or `Heaptype-sub`.

## SpectecType Ground-Term Cleanup

`SpectecType` is no longer a runtime terminal. Current generated prelude starts
with:

```maude
sort SpectecTerminal .
sort SpectecType .
sort SpectecCategory .
subsort SpectecType < SpectecCategory .
```

There is no longer:

```maude
subsort SpectecType < SpectecTerminal .
subsort SpectecTypes < SpectecTerminals .
```

Generic helpers that take source category labels now use `SpectecCategory`:

```maude
op $concat  : SpectecCategory SpectecTerminals -> SpectecTerminals .
op $disjoint : SpectecCategory SpectecTerminals -> Bool .
op $setminus : SpectecCategory SpectecTerminals SpectecTerminals -> SpectecTerminals .
```

Parametric type/category constructors now use source-shaped parameter sorts
instead of broad `SpectecTerminal` arguments:

```maude
op iN    : N -> SpectecType .
op vec   : Vnn -> SpectecType .
op binop : Numtype -> SpectecType .
op list  : SpectecCategory -> SpectecType .
```

So malformed terms such as `iN(CTORNOPA0)` are no longer well-sorted
`SpectecType` terms.

## Current Execution Evidence

Broad concrete audit:

```text
artifacts/rule-concrete-audit-20260525_004500/summary.md
total rl/crl: 830
REDUCED: 559
STUCK: 271
STACK_OVERFLOW: 0
MAUDE_EXIT: 0
TIMEOUT: 0
```

Interpretation: `STUCK` commands are generated concrete samples, not guaranteed
source-valid witnesses for every rule.

Focused all-pass matrix before the type-signature expectation drift:

```text
artifacts/c1-probe-matrix-20260525_004421/probe_summary.md
43 PASS
0 FAIL
0 STACK_OVERFLOW
```

Later typecheck/SpectecType cleanup evidence:

```text
artifacts/wasmtype-cleanup-audit-20260525_054200/summary.md
```

That audit records direct focused runtime success for:

- `steps(fib-config(i32v(5)))`;
- `steps(fib-config-invoke(i32v(5)))`;
- `$instantiate(empty-store, fib-module, eps)`;
- `steps(fib-init-config(i32v(5)))`;
- `examples/fib.wat -> generated-fib-init-config -> steps`;
- `examples/fib-wrapper.wat -> generated-fib-init-config -> wrapper call -> steps`;
- `examples/global-get.wat -> generated-run-config -> steps`;
- `examples/memory-size.wat -> generated-run-config -> steps`;
- `examples/table-size.wat -> generated-run-config -> steps`;
- `examples/start-global.wat -> generated-run-config -> steps`;
- `examples/data-load.wat -> active data init -> i32.load -> steps`;
- `examples/elem-call-ref.wat -> active elem init -> table.get/call_ref -> steps`;
- `examples/import-func.wat` with automatic function-import linking from
  `--import-func`;
- `examples/import-global.wat` with automatic imported-global linking from
  `--import-global`;
- `examples/import-memory.wat` with automatic imported-memory zero initialization;
- `examples/import-table.wat` with automatic imported-table default refs;
- `ref.test` positive and negative;
- `ref.cast` positive and negative.

The later probe matrix
`artifacts/c1-probe-matrix-20260525_054128/probe_summary.md` contains many
`FAIL` rows caused by stale expected-result sort strings after the type cleanup.
Use the direct runtime evidence above when discussing execution behavior.

## What To Ask Professor

1. Can C1 accept source-derived execution infrastructure such as
   `$is-spectec-val-seq` and `step-from-step-pure-ctxt-instrs`?
2. Can C1 accept `$infer-*` witness inference helpers, or should witness search
   be a C2 solver/execution layer?
3. Should C1 require every generated rule to have a source-valid concrete
   execution sample, or is structural coverage plus focused benchmark execution
   enough?
4. Should typed/mixed/nested sequence sorts be completed in C1, or can the
   broad `SpectecTerminals` carrier remain with minimal sequence-shape guards?
5. Are source-derived `otherwise` decision mirrors such as `$heaptype-sub?` and
   `$reftype-sub?` acceptable C1 infrastructure?
6. Is the source-derived focused active-element init bridge acceptable, or must
   active element initialization go through the literal generated `table.init`
   execution path in C1?

## What Not To Do

- Do not add init-config / WAT harness helpers directly to `output_bs.maude`;
  keep them in `wasm-init-bs.maude`.
- Do not add benchmark-specific shortcuts to `translator_bs.ml`.
- Do not add `mc`, `exec-step`, `focused-step`, or other C2 execution-control
  layers to C1.
- Do not remove Wasm type syntax or SpecTec validation semantics under the name
  of runtime typecheck cleanup.
- Do not treat old archive docs as current state unless `STATUS.md` or
  `docs/limitation.md` points to them explicitly.
