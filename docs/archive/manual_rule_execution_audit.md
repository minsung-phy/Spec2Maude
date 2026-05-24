# Manual rl/crl Execution Audit

Updated: 2026-05-23

이 문서는 `output_bs.maude`의 generated `rl` / `crl` 838개 전체에 대해
concrete Maude command를 생성하고 실행한 결과를 기록한다.

중요한 전제:

- 이것은 모든 가능한 input에 대한 수학적 증명이 아니다.
- 목표는 각 generated rule label마다 적어도 하나 이상의 명시적 concrete probe를 남기고,
  그 probe가 실제로 움직이는지 확인하는 것이다.
- 모든 probe 파일과 Maude log는 artifact directory에 보존한다.
- `STUCK`은 “현재 sample로는 움직이지 않았다”는 뜻이다. 곧바로 translator bug라는 뜻은 아니다.
  source-valid context/store/type witness가 부족한 sample 문제가 많다.

## Latest Operational Ledger

### Focused re-audit of the previous 344 non-reduced labels

Artifact:

```text
artifacts/manual-rule-focused-remaining-20260523_12/
```

This pass reruns every label from:

```text
artifacts/manual-rule-ledger-operational-20260523_03/non_reduced_labels.csv
```

with a larger source-valid sample catalog (`--max-variants 6`) and fixed result
classification.  In particular, the audit no longer lets an early
`STACK_OVERFLOW` variant override a later successful `REDUCED` variant.

Result for the 344 focused labels:

| status | count |
|---|---:|
| `REDUCED` | 73 |
| `STUCK` | 270 |
| `STACK_OVERFLOW` | 1 |
| total | 344 |

Important changes from the previous focused pass:

- `val-ok-num`, `val-ok-vec`, `val-ok-ref`, and `val-oks-cons` now reduce with
  source-valid value/type samples.
- `ref-ok-sub`, `step-read-br-on-cast-*`, `step-read-ref-test-*`,
  `step-read-ref-cast-*`, and `expr-ok-consts-cons` now reduce; earlier
  stack-overflow reports for these labels were audit-classification artifacts.
- `memarg-ok-r0` reduces after the source-variable case-collision fix.
- `externidx-ok-table`, `instr-ok-global-get`, and `instr-ok-global-set` reduce
  after source-derived typed indexing for flat composite record-field sequences.

The only remaining concrete `STACK_OVERFLOW` in this focused pass is:

```text
infer-instrs-ok-arg0-r3
```

This is an `$infer-*` witness-overlay rule for inferring a context from
`Instrs-ok/frame`-shaped information.  It is not a direct source rule, and it
belongs with the witness-synthesis / `$infer-*` limitation discussion.

The 270 remaining `STUCK` rows are bucketed in:

```text
artifacts/manual-rule-focused-remaining-20260523_12/nonreduced_bucket_summary.csv
```

Summary buckets:

| bucket | count |
|---|---:|
| `INSTR_VALIDATION_NEEDS_RICH_CONTEXT_OR_CATEGORY_SORT_FIX` | 71 |
| `INFER_OVERLAY_NEEDS_WITNESS_OR_SAMPLE` | 62 |
| `RECURSIVE_TYPE_OR_COMPOSITE_CATEGORY_SORT_GAP` | 37 |
| `SIMD_VECTOR_RUNTIME_OR_BUILTIN_SAMPLE` | 26 |
| `RUNTIME_STORE_FRAME_STACK_SAMPLE` | 22 |
| `OTHER_COHERENT_SOURCE_SAMPLE_NEEDED` | 20 |
| `SOURCE_STAR_LIST_VALIDATION_SAMPLE_OR_WITNESS` | 18 |
| `STORE_REF_VALUE_VALIDATION_SAMPLE` | 11 |
| `INIT_EVAL_OUTPUT_WITNESS` | 3 |

Key diagnosis from manual spot checks:

- Some stuck labels still need richer coherent source states, stores, modules,
  or recursive type contexts.
- Some stuck labels already have reasonable-looking samples but cannot match
  because composite source categories such as `limits`, `memtype`, `tabletype`,
  and related flat encodings are represented as broad `SpectecTerminal` terms
  plus membership axioms.  Maude rule matching does not always use those
  membership axioms as if the constructor directly returned the source sort.
  This is the category/sequence sort representation gap described in
  [docs/limitation.md](limitation.md).

### Baseline full operational ledger

Artifact:

```text
artifacts/manual-rule-ledger-operational-20260523_03/
```

검사 방식:

```maude
rew [100] in C1-RULE-CONCRETE-SAMPLES :
  <instantiated rule lhs> .
```

판정 기준:

- `REDUCED`: concrete LHS가 `valid`, `Config`, `SpectecTerminals` 등 다른 top-level 결과로 줄었다.
- `STUCK`: result가 여전히 같은 top-level relation/function call로 남았다.
- `STACK_OVERFLOW`: Maude stack overflow.

결과:

| status | count |
|---|---:|
| `REDUCED` | 494 |
| `STUCK` | 343 |
| `STACK_OVERFLOW` | 1 |
| total | 838 |

Full files:

```text
artifacts/manual-rule-ledger-operational-20260523_03/rule_concrete_results.csv
artifacts/manual-rule-ledger-operational-20260523_03/non_reduced_labels.csv
artifacts/manual-rule-ledger-operational-20260523_03/non_reduced_summary.md
```

## Non-Reduced Buckets

Current non-reduced labels are grouped as follows:

| bucket | count |
|---|---:|
| `Instr-ok` validation needs richer source context/type/index sample | 83 |
| `$infer-instr-ok` witness overlay needs matching instruction sample | 40 |
| `Step-read` runtime needs source-shaped store/frame/stack sample | 37 |
| `Step-pure` runtime needs source-shaped stack/value/vector sample | 33 |
| Other sample/witness triage | 28 |
| `$infer-*` witness overlay sample or witness limitation | 24 |
| Module validation needs coherent module/context witness | 23 |
| Recursive type/typeuse/deftype context or rolling sample | 17 |
| Source-star cons rule sample catalog lacks correct leading context/store arg | 17 |
| Store/value/ref validation needs source-shaped store instance | 15 |
| Heaptype subtype needs recursive type context witness | 11 |
| Known non-C1 label shortcut needs context-prefix sample | 10 |
| Expand/typeuse needs source type context/deftype sample | 3 |
| Eval/instantiate output-bearing relation premise sample | 3 |

The complete label list is in:

```text
artifacts/manual-rule-ledger-operational-20260523_03/non_reduced_labels.csv
```

## Exact RHS Search Ledger

There is also an older exact-search pass:

```text
artifacts/manual-rule-ledger-hand-catalog-20260523_01/
```

That pass asks a stricter question:

```maude
search [1] in C1-RULE-CONCRETE-SAMPLES :
  <instantiated lhs> =>+ <instantiated rhs> .
```

Result:

| status | count |
|---|---:|
| `SOLUTION` | 380 |
| `NO_SOLUTION` | 439 |
| `MAUDE_EXIT_2` | 16 |
| `STACK_OVERFLOW` | 2 |
| `TIMEOUT` | 1 |

This exact RHS test undercounts executability because many source rules have output witnesses,
associative sequence splits, or RHS values that are hard to instantiate correctly from a broad
sample catalog. Therefore the operational `rew LHS` ledger is the better smoke test for
“does this concrete rule shape move at all?”

## Focused Rechecks

Several scary rows from the broad exact ledger were rechecked with source-valid probes and pass.

Examples:

- `expr-ok-const-r0`
- `step-pure-br-label-zero`
- `step-pure-br-label-succ`
- `step-pure-return-label`
- `step-read-br-on-cast-succeed`
- `step-read-throw-ref-handler-catch`
- `step-read-array-new-elem-alloc`
- `step-read-array-fill-succ`

Artifact:

```text
artifacts/phase1-error-triage-20260523_001928/
```

## Current Honest Conclusion

What is confirmed:

- All 838 generated `rl/crl` labels have explicit concrete probe files and logs
  from the baseline full ledger.
- The previous 344 non-reduced labels were rerun in a focused pass.
- In that focused pass, 73 / 344 now reduce, 270 remain stuck under the current
  sample catalog, and 1 remains stack-overflowing.
- The remaining non-reduced set is explicitly enumerated and bucketed.

What is not proven:

- The 270 remaining stuck labels are not all confirmed semantic bugs.
- Many need better source-valid witnesses: richer context, store, module
  instance, table/memory/GC/SIMD values, or output witness synthesis.
- A subset exposes the broader category/sequence sort representation gap where
  source categories are encoded by membership axioms rather than precise
  constructor result sorts.

Recommended next step:

1. Treat `infer-instrs-ok-arg0-r3` as the next focused stack-overflow item.
2. Decide whether to attack the category/sequence sort representation gap next,
   because it blocks many apparently simple validation samples.
3. For runtime/SIMD/module buckets, prefer benchmark-level focused repros over
   more blind sample generation.
