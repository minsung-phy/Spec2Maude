# C1 Limitations And Discussion Notes

Updated: 2026-05-27

This is the current source of truth for C1 limitations.  Older files under
`docs/archive/` are historical evidence, not the current project state.

## 0. Current Conclusion

`output_bs.maude` structurally covers the WebAssembly 3.0 SpecTec source in
this repository and loads without Maude warnings through the runtime harness.

```text
source files:                       21 / 21
syntax declarations:                249 / 249
def declarations/equations:          1272 / 1272
relation declarations:               82 / 82
rule declarations:                   499 / 499
strict validation source-rule targets: 281 / 281 primary rl/crl
missing source construct:            none currently known
eq/ceq ... = valid:                  0
iter-empty / opt-empty labels:       0
```

The current research question is:

```text
How far can we keep the generated Maude structurally isomorphic to the SpecTec
source while still making the result executable enough for concrete Wasm
programs and benchmark tests?
```

## 1. Isomorphism Criteria

C1 currently aims for:

1. SpecTec source syntax / def / rule structure and intent are preserved.
2. SpecTec `def` lowers to Maude `eq/ceq`.
3. SpecTec `rule` lowers to Maude `rl/crl`.
4. Unconditional source rules stay unconditional when possible.
5. Source-absent helper names/rules are avoided in `output_bs.maude` unless
   they are unavoidable representation infrastructure, mechanically derived
   execution infrastructure, or explicitly accepted after discussion.

## 2. Resolved Or Improved Items

### 2.1 `step-from-step-pure-*`

Current output:

```text
step-from-step-pure count: 0
```

The former context-step shortcut rules are no longer generated.

### 2.2 `$is-spectec-val-seq`

Current output:

```text
$is-spectec-val-seq: absent
$is-spectec-val: absent
```

Instead, source `val*` is represented with a Maude sort:

```maude
sort ValSeq .
subsort Val < ValSeq .
subsort ValSeq < SpectecTerminals .
op eps : -> ValSeq .
op _ _ : ValSeq ValSeq -> ValSeq [ctor assoc id: eps] .
```

This lets rules such as `Step/ctxt-instrs` use a sorted `VALS : ValSeq`
variable rather than a source-absent Boolean guard.

### 2.3 SpectecType ground-term universe

The old overly broad shape allowed meaningless type terms such as
`iN(CTORNOPA0)`.  This was a translator bug, not a research feature.

Current design separates runtime terminals from category/type labels:

```maude
sort SpectecTerminal .
sort SpectecType .
sort SpectecCategory .
subsort SpectecType < SpectecCategory .
```

Removed:

```maude
subsort SpectecType < SpectecTerminal .
subsort SpectecTypes < SpectecTerminals .
```

Parametric type/category constructors now use narrower source-shaped parameter
sorts:

```maude
op iN    : N -> SpectecType .
op vec   : Vnn -> SpectecType .
op binop : Numtype -> SpectecType .
op list  : SpectecCategory -> SpectecType .
```

Generic source helpers that take a syntax/category parameter now take
`SpectecCategory`, not any runtime terminal:

```maude
op $concat   : SpectecCategory SpectecTerminals -> SpectecTerminals .
op $disjoint : SpectecCategory SpectecTerminals -> Bool .
op $setminus : SpectecCategory SpectecTerminals SpectecTerminals -> SpectecTerminals .
```

## 3. Remaining Non-Isomorphic / Discussion Items

### 3.1 `$infer-*` witness inference

SpecTec relation premises can introduce witnesses used by later premises.

Example:

```spectec
rule Instrs_ok/seq:
  C |- instr_1 instr_2* : t_1* ->_(x_1* x_2*) t_3*
  -- Instr_ok: C |- instr_1 : t_1* ->_(x_1*) t_2*
  -- Instrs_ok: ... |- instr_2* : t_2* ->_(x_2*) t_3*
```

Here `t_2*` is produced by the first premise and consumed by the second.
The current Maude validity encoding:

```maude
Instr-ok(...) => valid
```

checks validity but does not directly return the witness.  The translator
therefore generates `$infer-*` helpers from the source premise structure.

Classification:

- not benchmark hardcoding;
- mechanically derived from source relation premises;
- still strict non-isomorphic because the source does not literally contain
  `$infer-*` relations.

Discussion question:

```text
Should witness inference helpers be allowed in C1, or should they be separated
as a C2 execution/solver layer?
```

### 3.2 Relation decision mirrors

Current subtype `otherwise` execution uses Boolean mirrors such as:

```text
$heaptype-sub?
$reftype-sub?
```

They are generated from source subtype rules to make success/failure branching
executable.  They are not hand-coded Wasm cases, but they are still source-absent
helper names.

Discussion question:

```text
Are source-derived decision mirrors acceptable for translating SpecTec
otherwise-priority behavior into executable Maude?
```

### 3.3 Def execution scaffolding

Some SpecTec `def` clauses contain ordered premises and witness passing.  The
translator keeps them as Maude `eq/ceq`, but uses source-derived scaffolding:

```text
$cont-*
$result-*
$valid-*
$map-*
```

Discussion question:

```text
Is this acceptable as executable equation infrastructure, or should it be
reported as non-isomorphic support code outside the C1 core?
```

### 3.4 Init/runtime harness helpers

`wasm-init-bs.maude` contains frontend/init/runtime harness helpers.  These are
not part of the generated SpecTec core and should be discussed separately from
`output_bs.maude`.

Current rule:

```text
Do not move frontend/init harness code into output_bs.maude unless it is truly
source-derived and translator-generated.
```

## 4. Typecheck / Validation Direction

The correct statement is not "typecheck was removed."

The correct statement is:

```text
SpecTec validation semantics remain.
Duplicate/generated runtime category guards were reduced or moved into better
source-shaped representations such as ValSeq.
```

Still present:

```text
Module-ok
Func-ok
Instr-ok
Instrs-ok
Reftype-sub
Heaptype-sub
```

Removed/reduced from the runtime core path:

```text
hasType / WellTyped
general $is-spectec-* runtime predicates
$is-spectec-val-seq
```

Invalid input handling:

- normal frontend path rejects invalid `.wat` / `.wasm` through WABT;
- checked execution is gated by Maude `Module-ok`;
- if `Module-ok` does not rewrite to `valid`, the generated checked run does
  not enter `$instantiate` or `steps`.

For formal reporting, emphasize the Maude `Module-ok` gate. WABT is useful for
engineering hygiene but should not be the only formal argument.

## 5. Current Benchmark State

Latest checked benchmark summary:

```text
artifact: artifacts/c1-regression-20260527_133237/wasm-benchmarks/benchmark_results.csv

total: 568
PASS: 319
STEPPED: 74
INVALID: 21
NO_ENTRY: 58
IMPORT_MISSING: 5
UNSUPPORTED: 4
STUCK_VALIDATION: 46
STUCK_STEP: 8
WRONG_RESULT: 33
```

Meaning:

- `PASS`: fully successful case with expected result.
- `STEPPED`: execution ended, but no expected result was available.
- `INVALID`: invalid module rejected or `Module-ok` did not prove valid.
- `NO_ENTRY`: module has no callable export/main function.
- `IMPORT_MISSING`: host import is required but not linked.
- `UNSUPPORTED`: syntax or instruction family not supported yet.
- `STUCK_VALIDATION`: validation executability gap.
- `STUCK_STEP`: runtime executability gap.
- `WRONG_RESULT`: runtime result mismatch.

## 6. Current Frontend Scope

The WAT/Wasm frontend currently supports:

```text
module/type/func/import/export
global/memory/table/data/elem/start
direct call/call_ref/call_indirect
block/loop/if/br/br_if/br_table
local/global get/set/tee
memory load/store/init/copy/fill/size/grow
table get/set/size/grow/fill/init/copy/elem.drop
i32/i64/f32/f64 constants, numeric ops, relops, conversions
selected v128/SIMD/relaxed-SIMD term generation
selected ref types and ref instructions
```

Still incomplete:

```text
full WAT grammar
all proposal/custom syntax
structured exception/tag runtime coverage
all SIMD/relaxed-SIMD execution semantics
all GC/recursive type proposal paths
complete WASI/browser import environment
```

## 7. Current Runtime/Validation Gaps

Priority buckets:

1. `STUCK_VALIDATION`
   - `Module-ok` / `Instrs-ok` execution gaps.
   - Examples include table64/memory64 validation, local initialization,
     unreachable/polymorphic typing, and proposal instruction forms.
2. `STUCK_STEP`
   - Runtime rules or builtins do not finish.
   - Examples include memory fill/copy/grow, ref/null paths, and SIMD admin
     contexts.
3. `WRONG_RESULT`
   - Execution finishes with an incorrect value.
   - Examples include memory byte operations, data/drop state, linking/import
     state, float memory, and ref checks.
4. `UNSUPPORTED`
   - Frontend or WABT cannot yet parse/support the syntax.

## 8. What To Ask Professor

Recommended questions:

1. `val*` is now represented by `ValSeq`, not `$is-spectec-val-seq`. Is this
   the right C1 direction for source category preservation?
2. Can `$infer-*` witness inference be considered acceptable source-derived
   execution infrastructure, or should it be moved to a separate layer?
3. Are subtype decision mirrors for `otherwise` acceptable in C1?
4. Should the paper's formal path require Maude `Module-ok` checked execution
   for all frontend runs?
5. What is the expected C1 acceptance criterion: structural coverage plus
   benchmark execution, or every generated rule executable on a source-valid
   concrete witness?

## 9. Recommended Next Work

1. Reduce `STUCK_VALIDATION`.
2. Reduce `STUCK_STEP`.
3. Reduce `WRONG_RESULT`.
4. Expand unsupported frontend syntax only after the first three buckets shrink.
5. Continue moving non-source frontend/init code out of `output_bs.maude`.
6. Maintain a paper-ready benchmark table from `scripts/run_wasm_benchmarks.py`.

## 10. Things Not To Do

- Do not claim full WebAssembly support yet.
- Do not claim typecheck was simply removed.
- Do not treat WABT as the only formal validation argument.
- Do not put frontend/init harness helpers directly into `output_bs.maude`.
- Do not assume all `STUCK_VALIDATION` cases are frontend bugs; some are Maude
  validation executability gaps.
