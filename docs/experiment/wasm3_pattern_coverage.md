# wasm-3.0 Spectec 패턴 커버리지 정리

작성일: 2026-04-17
범위: wasm-3.0/*.spectec (총 21개 파일)

## 1) 한 줄 요약

- 통사(문법/정의) 변환은 광범위하게 자동 처리된다.
- 다만 실행 의미론 핵심 일부(특히 RulePr bridge, Steps/trans, call_ref-func)는 현재 자동 변환이 완결되지 않았다.

## 1.1) 총 몇 개 중 몇 개가 변환되는가

- 총 규칙 수: 501개
- 자동 변환됨: 477개
  - `translated_auto`: 473개
  - `translated_auto_heat_cool`: 4개
- 자동 변환 안됨: 24개 (`not_translated_auto`)

요약하면, 현재 기준 자동 변환 커버리지는 $\frac{477}{501} \approx 95.2\%$ 이고,
미변환은 24개(약 4.8%)다.

미변환 24개를 원인별로 묶으면:

| 원인 | 개수 | 규칙 |
|---|---:|---|
| Step bridge 규칙 스킵(translate_step_reld 경로) | 2 | Step/pure, Step/read |
| Step-family premise 포함 Steps/trans 스킵 | 1 | Steps/trans |
| 수동 보정 의존(call_ref-func) | 1 | Step_read/call_ref-func |
| output 라벨 미생성(현재 생성물 기준) | 20 | 아래 5.1 표 참조 |

## 2) 집계 방법

- 코퍼스 전체에서 top-level 키워드(syntax/relation/def/rule)와 premise 마커(-- if, -- otherwise, -- Expand:, -- Relation:)를 집계했다.
- 변환 가능 여부는 translator 구현 경로로 판정했다.
  - RelD 분기: translate_step_reld / translate_reld
  - premise 분기: IfPr / RulePr / LetPr / ElsePr / IterPr / NegPr
  - 스킵 조건: RulePr 포함 Step 규칙 스킵, Step 전제를 가진 비-Step 관계 규칙 스킵

근거 코드:
- translator 분기: [translator.ml](../translator.ml)
- premise AST 타입: [lib/il/ast.ml](../lib/il/ast.ml)
- 실행 규칙 원본: [wasm-3.0/4.3-execution.instructions.spectec](../wasm-3.0/4.3-execution.instructions.spectec)
- 현재 생성물: [output.maude](../output.maude)
- 수동 보정 모듈: [wasm-exec.maude](../wasm-exec.maude)

## 3) 전역 패턴 표 (코퍼스 전체)

| 패턴 | 등장 수 | 현재 변환 상태 | 비고 |
|---|---:|---|---|
| syntax 선언 | 249 | 변환됨 | TypD 경로로 변환 |
| relation 선언 | 82 | 대부분 변환 | Step 계열은 전용 경로, 나머지는 Bool 관계 경로 |
| def 선언 | 1277 | 변환됨 | DecD 경로로 변환 |
| rule 선언 | 501 | 부분 변환 | 일부 RulePr 기반 규칙은 스킵/수동 보정 필요 |
| premise: -- if | 267 | 변환됨 | IfPr -> Bool 조건 |
| premise: -- otherwise | 34 | 변환됨 | ElsePr -> owise |
| premise: -- Relation: ... (RulePr) | 249 | 부분 변환 | 핵심 gap 구간 (아래 5절) |
| premise: -- Expand: ... | 48 | 부분 변환 | 대부분 반영되나 일부 실행 규칙은 수동 보정 필요 |
| premise 내 <- (membership/binding) | 12 | 변환됨 | PremEq 바인딩/조건으로 번역 |
| premise 내 =/= 계열 | 8 | 변환됨 | Bool 비교식으로 번역 |
| 반복형 premise 스타일 ( ... )* | 31 | 부분 변환 | IterPr를 현재 inner prem으로 평탄화 |
| 부정 premise 스타일 (if not / not) | 0 | 코퍼스 미사용 | NegPr 경로는 존재하나 현재 inner prem으로 평탄화 |

## 4) 파일별 패턴 footprint + 상태

| 파일 | syntax | relation | def | rule | 상태 |
|---|---:|---:|---:|---:|---|
| wasm-3.0/0.1-aux.vars.spectec | 5 | 0 | 0 | 0 | 변환됨 |
| wasm-3.0/0.2-aux.num.spectec | 0 | 0 | 9 | 0 | 변환됨 |
| wasm-3.0/0.3-aux.seq.spectec | 0 | 0 | 35 | 0 | 변환됨 |
| wasm-3.0/1.0-syntax.profiles.spectec | 0 | 0 | 1 | 0 | 변환됨 |
| wasm-3.0/1.1-syntax.values.spectec | 39 | 0 | 71 | 0 | 변환됨 |
| wasm-3.0/1.2-syntax.types.spectec | 42 | 0 | 292 | 0 | 변환됨 |
| wasm-3.0/1.3-syntax.instructions.spectec | 99 | 0 | 134 | 0 | 변환됨 |
| wasm-3.0/1.4-syntax.modules.spectec | 15 | 0 | 37 | 0 | 변환됨 |
| wasm-3.0/2.0-validation.contexts.spectec | 4 | 0 | 16 | 0 | 변환됨 |
| wasm-3.0/2.1-validation.types.spectec | 2 | 27 | 8 | 42 | 변환됨 (관계식 변환) |
| wasm-3.0/2.2-validation.subtyping.spectec | 0 | 16 | 0 | 50 | 변환됨 (관계식 변환) |
| wasm-3.0/2.3-validation.instructions.spectec | 0 | 11 | 2 | 140 | 변환됨 (관계식 변환) |
| wasm-3.0/2.4-validation.modules.spectec | 1 | 18 | 2 | 28 | 변환됨 (관계식 변환) |
| wasm-3.0/3.0-numerics.relaxed.spectec | 2 | 0 | 15 | 0 | 변환됨 |
| wasm-3.0/3.1-numerics.scalar.spectec | 0 | 0 | 298 | 0 | 변환됨 |
| wasm-3.0/3.2-numerics.vector.spectec | 0 | 0 | 166 | 0 | 변환됨 |
| wasm-3.0/4.0-execution.configurations.spectec | 40 | 0 | 104 | 0 | 변환됨 |
| wasm-3.0/4.1-execution.values.spectec | 0 | 5 | 6 | 22 | 부분 (Steps 품질 의존) |
| wasm-3.0/4.2-execution.types.spectec | 0 | 0 | 10 | 0 | 변환됨 |
| wasm-3.0/4.3-execution.instructions.spectec | 0 | 5 | 3 | 219 | 부분 (핵심 gap 존재) |
| wasm-3.0/4.4-execution.modules.spectec | 0 | 0 | 68 | 0 | 변환됨 |

## 5) 핵심 gap 표 (변환 안 되거나 부분 처리)

| 패턴 | 원본 위치 | 현재 상태 | 근거 |
|---|---|---|---|
| Steps/trans (Step + Steps 전제 체인) | [wasm-3.0/4.3-execution.instructions.spectec](../wasm-3.0/4.3-execution.instructions.spectec#L24) | 자동 변환 누락 | output에는 Steps/refl만 생성됨 ([output.maude](../output.maude#L7476)) |
| Step_read/call_ref-func | [wasm-3.0/4.3-execution.instructions.spectec](../wasm-3.0/4.3-execution.instructions.spectec#L180) | 자동 변환 누락, 수동 보정 | output에 step-read-call-ref-func 라벨 없음, 대신 [wasm-exec.maude](../wasm-exec.maude#L60)에 수동 ceq |
| RulePr 포함 Step 규칙 일반 케이스 | 실행 규칙 전반 | 스킵 | translator에서 RulePr가 있으면 context 특례 외 스킵 ([translator.ml](../translator.ml#L1845)) |
| context decode 실패 케이스 | Step context 규칙 일부 가능성 | 스킵 | decode 실패 시 빈 문자열 반환 ([translator.ml](../translator.ml#L1871), [translator.ml](../translator.ml#L1873)) |
| Step 전제를 가진 비-Step 관계 규칙 | Steps/trans 등 | 스킵 | has_step_exec_rule_premise면 스킵 ([translator.ml](../translator.ml#L2226)) |
| IterPr 의미 | 여러 validation 규칙의 반복 premise | 부분 | IterPr를 inner prem으로 평탄화 ([translator.ml](../translator.ml#L759)) |
| NegPr 의미 | 코퍼스에서는 0건 | 미검증/잠재 미지원 | NegPr를 inner prem으로 평탄화 ([translator.ml](../translator.ml#L759)) |
| $rollrt 브리지 | 함수 정의 변환 | 특수 하드코딩 | 전용 분기 존재 ([translator.ml](../translator.ml#L1728)) |

## 5.1) 자동 변환 안되는 24개 규칙 (정확 목록)

| 파일:라인 | rule_name | 사유 |
|---|---|---|
| wasm-3.0/4.3-execution.instructions.spectec:13 | Step/pure | Bridge rule skipped in translate_step_reld (RulePr + non-context decode). |
| wasm-3.0/4.3-execution.instructions.spectec:17 | Step/read | Bridge rule skipped in translate_step_reld (RulePr + non-context decode). |
| wasm-3.0/4.3-execution.instructions.spectec:24 | Steps/trans | Skipped in translate_reld when premise references Step family. |
| wasm-3.0/4.3-execution.instructions.spectec:149 | Step_read/br_on_cast-succeed | Expected step label missing in output. |
| wasm-3.0/4.3-execution.instructions.spectec:160 | Step_read/br_on_cast_fail-succeed | Expected step label missing in output. |
| wasm-3.0/4.3-execution.instructions.spectec:180 | Step_read/call_ref-func | Auto-translation missing; manual rule exists in wasm-exec.maude. |
| wasm-3.0/4.3-execution.instructions.spectec:203 | Step_read/return_call_ref-frame-addr | Expected step label missing in output. |
| wasm-3.0/4.3-execution.instructions.spectec:231 | Step/throw | Expected step label missing in output. |
| wasm-3.0/4.3-execution.instructions.spectec:667 | Step_read/ref.test-true | Expected step label missing in output. |
| wasm-3.0/4.3-execution.instructions.spectec:678 | Step_read/ref.cast-succeed | Expected step label missing in output. |
| wasm-3.0/4.3-execution.instructions.spectec:700 | Step/struct.new | Expected step label missing in output. |
| wasm-3.0/4.3-execution.instructions.spectec:706 | Step_read/struct.new_default | Expected step label missing in output. |
| wasm-3.0/4.3-execution.instructions.spectec:715 | Step_read/struct.get-struct | Expected step label missing in output. |
| wasm-3.0/4.3-execution.instructions.spectec:724 | Step/struct.set-struct | Expected step label missing in output. |
| wasm-3.0/4.3-execution.instructions.spectec:735 | Step_read/array.new_default | Expected step label missing in output. |
| wasm-3.0/4.3-execution.instructions.spectec:740 | Step/array.new_fixed | Expected step label missing in output. |
| wasm-3.0/4.3-execution.instructions.spectec:758 | Step_read/array.new_data-oob | Expected step label missing in output. |
| wasm-3.0/4.3-execution.instructions.spectec:765 | Step_read/array.new_data-num | Expected step label missing in output. |
| wasm-3.0/4.3-execution.instructions.spectec:779 | Step_read/array.get-array | Expected step label missing in output. |
| wasm-3.0/4.3-execution.instructions.spectec:792 | Step/array.set-array | Expected step label missing in output. |
| wasm-3.0/4.3-execution.instructions.spectec:845 | Step_read/array.copy-le | Expected step label missing in output. |
| wasm-3.0/4.3-execution.instructions.spectec:857 | Step_read/array.copy-gt | Expected step label missing in output. |
| wasm-3.0/4.3-execution.instructions.spectec:905 | Step_read/array.init_data-oob2 | Expected step label missing in output. |
| wasm-3.0/4.3-execution.instructions.spectec:918 | Step_read/array.init_data-num | Expected step label missing in output. |

## 6) 4.3 실행 규칙 패밀리 상세

원본 규칙 수 (4.3):
- Step/: 32
- Step_pure/: 79
- Step_read/: 105
- Steps/: 2
- Eval_expr: 1

context 규칙(원본):
- Step/ctxt-instrs, Step/ctxt-label, Step/ctxt-handler, Step/ctxt-frame

현재 생성물 관찰:
- output step 라벨 규칙 수: 189
- output context heat/cool 라벨 수: 8
- step-read-call: 존재
- step-read-call-ref-null: 존재
- step-read-call-ref-func: 부재

## 7) 지금 기준 결론

- 변환되고 있는 것:
  - syntax/def 중심의 통사 변환
  - validation 관계식 다수
  - Step/Step_pure/Step_read의 대다수 직접 규칙
  - context heat/cool 자동 생성(핵심 4종)
- 안 되거나 부분인 것:
  - RulePr bridge 계열의 완전 자동화
  - Steps/trans 자동 변환
  - call_ref-func 자동 변환
  - IterPr/NegPr 의미를 보존하는 정밀 번역

즉, "전체 파일을 자동으로 읽어 Maude를 만든다"는 점은 이미 달성되어 있으나, "SpecTec 실행 의미를 손수 보정 없이 1:1로 보존"은 아직 미완이다.

## 8) 부록: 전 규칙(501개) 행 단위 상태표

- 규칙 단위 전체 목록(CSV): [docs/wasm3_rule_pattern_status.csv](wasm3_rule_pattern_status.csv)
- 컬럼: file, line, rule_name, category, status, note
- 행 수: 헤더 제외 501행

## 9) 부록: 미변환 규칙의 Spectec 원문

요청한 "변환 안되는 부분의 spectec 원본"은 아래 파일에 24개 전부 수록했다.

- [docs/wasm3_not_translated_rules.txt](wasm3_not_translated_rules.txt)

구성:
- 각 항목 헤더: `file:line rule_name`
- 해당 규칙의 Spectec 원문 블록 전체
- 항목 구분선(`--------------------------------------------------------------------------------`)
