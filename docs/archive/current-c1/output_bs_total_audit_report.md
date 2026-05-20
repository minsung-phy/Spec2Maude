# output_bs.maude 전체 concrete artifact audit

Updated: 2026-05-21

이 문서는 `output_bs.maude` 안의 generated artifact 전체를 대상으로 한
concrete 실행 audit 결과다.

중요: 이 audit은 수학적 증명이 아니다. 각 artifact마다 하나 이상의 concrete
sample command를 만들어 Maude에서 실제로 돌려 본 것이다. `NO_SOLUTION`이나
`STUCK`은 곧바로 “규칙이 틀렸다”는 뜻이 아니라, 자동 sample이 source premise를
만족하지 못했거나 필요한 witness/context/store가 부족하다는 뜻일 수 있다.

## 실행한 명령

```bash
python3 scripts/audit_output_bs_total_concrete.py --timeout 2
```

결과:

```text
artifacts/output-bs-total-audit-20260521_012550/
├── inventory.csv
├── test_results.csv
├── summary.md
├── maude-tests/
└── logs/
```

`maude-tests/` 아래에는 각 artifact별로 실제 Maude command가 남아 있다.

## Inventory count

| kind | count |
|---|---:|
| op | 1202 |
| eq | 997 |
| ceq | 280 |
| mb | 424 |
| cmb | 118 |
| rl | 110 |
| crl | 774 |
| **total** | **3905** |

## 결과 요약

아래 count는 `artifacts/output-bs-total-audit-20260521_012550/`의 기존 full run
기준이다. 이후 7개 위험 failure triage에서 translator와 sample generator가
개선되었으므로, 정확한 최신 count는 total audit을 다시 돌리면 갱신된다.

| status | count |
|---|---:|
| PASS | 2892 |
| KNOWN_LIMITATION | 41 |
| NO_SOLUTION | 653 |
| STUCK | 312 |
| STACK_OVERFLOW | 3 |
| MAUDE_EXIT_2 | 4 |

해석:

- `PASS`: concrete command가 Maude 결과를 냈거나, rule search에서 solution을 찾았다.
- `KNOWN_LIMITATION`: 이미 C1 limitation으로 분류된 경로와 일치한다.
- `NO_SOLUTION`: 자동 sample이 해당 rule premise를 만족하지 못했다. 바로 bug는 아니다.
- `STUCK`: membership/condition probe가 true까지 가지 못했다. 대부분 sample 품질 문제 또는 category witness 부족이다.
- `STACK_OVERFLOW`: focused repro가 필요한 우선 조사 대상이다.
- `MAUDE_EXIT_2`: Maude internal error 또는 malformed sample 가능성이 있다.

## 7개 위험 failure focused triage 결과

상세 내용은 `docs/dangerous_failure_triage.md`에 있다.

| artifact | 이전 status | focused 결과 |
|---|---|---|
| `$concatn` | `STACK_OVERFLOW` | generic `ListN` 길이 조건과 tail sequence sort 보정으로 stack overflow 제거 |
| `$ivbitmaskop` | `STACK_OVERFLOW` | 아직 limitation: non-variable `e*`, `e^n`, inverse hint lowering 부족 |
| `$vbitmaskop` | `STACK_OVERFLOW` | `$ivbitmaskop` 위임이므로 동일 limitation |
| `clos-deftypes-r1` | `MAUDE_EXIT_2` | source-valid `rew` probe는 Maude result 생성; 기존 failure는 audit sample/search 문제 |
| `step-read-array-new-elem-alloc` | `MAUDE_EXIT_2` | source-shaped elem store + `n = 1` probe는 solution 생성; 기존 failure는 sample 문제 |
| `alloctypes-r1` | `MAUDE_EXIT_2` | source-valid `rew` probe는 Maude result 생성; 기존 failure는 audit sample/search 문제 |
| `evalexprss-r1` | `MAUDE_EXIT_2` | 아직 limitation: `expr**`가 flat `WasmTerminals`로 표현되어 recursive grouping이 비감소 split 가능 |

## Known limitation으로 잡힌 항목

이번 full audit에서 자동으로 `KNOWN_LIMITATION`으로 분류된 것은 41개다.

대표 family:

- `Expr-ok-const`, `Global-ok`, `Table-ok`, `Elem-ok` 등: `Instrs-ok(CONST ...)` 실행 limitation을 타고 막힘.
- `step-from-step-pure-*` 20개: label-related executable debt.
- `invoke-r0`: invoke / outer-frame path limitation.
- `$iter-expr-ok-const-*`: 위 `Expr-ok-const` limitation을 반복 premise lowering에서 만난 것.

## 왜 PASS가 3905/3905가 아닌가

전체 artifact에 대해 “아무 concrete term 하나”를 넣는 것은 충분하지 않다. 많은
rule은 source premise를 만족하는 정교한 context/store/module/list witness가 필요하다.

예:

- `Instr-ok/call`은 `C.FUNCS[x]`가 함수 type으로 풀리는 context가 필요하다.
- `step-read-array-new-elem-alloc`은 source-shaped store/array/heap state가 필요하다.
- `$iter-*` helper는 각 반복 element가 내부 relation premise를 만족해야 한다.
- membership axiom은 단순 `CTORI32A0` 하나로는 target category를 만족하지 않는 경우가 많다.

따라서 이번 audit은 “전체 artifact에 대해 concrete command를 생성하고 실제로 돌리는
기반”을 만든 것이고, 남은 `NO_SOLUTION`/`STUCK`은 다음 triage queue다.

## 다음 triage 순서

1. `STACK_OVERFLOW` 3개를 source-valid focused sample로 재검증한다.
2. `MAUDE_EXIT_2` 4개가 sample 문제인지 generator 문제인지 확인한다.
3. `NO_SOLUTION` 중 source primary rule부터 우선순위를 둔다. `$infer-*` / `$iter-*` helper는 그 다음이다.
4. membership `STUCK`은 sample catalog를 더 똑똑하게 만든 뒤 재실행한다.
5. 그래도 source-valid sample에서 실패하는 항목만 `docs/limitation.md`에 true limitation으로 승격한다.
