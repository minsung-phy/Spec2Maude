# baseline2 비교 기준

출발점: `main`의 `30aeb73e45f064c7cc755f9a38620bb5c7d22b14`.
기존 `baseline` (`cb10d39`)과 `main` ref는 변경하지 않는다.
현재 translator의 오류 수정과 지원 범위를 기준으로 최적화 적용을 제거한다.
과거 baseline의 `runSeq` 압축 표현은 복원하지 않는다.

## 제거한 실행 최적화

- Wasm source의 `maude_sort`, `maude_subsort`, `maude_proper`, `maude_context`.
  생성물에는 typed list 및 focus/heat/cool 구현이 없어야 한다.
- `len [memo]`, sequence cursor, 32개 단위 순회, `spliceAux`,
  반복 목록 doubling. 일반 목록의 단순 재귀와 범위 검사를 사용한다.
- record lookup의 `[owise]` fallback과 직접 field forwarding 단축.
- builtin의 native power 치환, binary digit 기반 logarithm 계산,
  UTF-8 tail 검사 생략. 기존 재귀 계산 및 tail 검사를 사용한다.
- WAST의 focus 전용 host-call rule과 memo 초기화 명령.

## 유지한 변경과 연결 수정

- 최신 relation 입력의 구조적 pattern 보존, source premise/guard,
  `$fbits_` inverse 수정, DET NaN 처리, scalar 표현, subtype backend 수정.
- slice/update의 범위 밖 실패와 부분 연산 선언. backend 전체를 옛 파일로
  되돌리지 않는다.
- `wasm2maude`와 handwritten relation backend는 `SpectecTerminals`를 사용한다.
  modelcheck의 종료 rule은 `typecheck(RESULT, val)`로 결과를 구별한다.
  일반 host-call rule과 host argument 검사는 유지한다.
- 선택적 hint 지원 OCaml 코드는 보존한다. 이 브랜치의 pinned source에는
  해당 hint가 없으므로 최적화가 생성되지 않는다.
- 균형 괄호 출력과 64개 command 분할은 main과 동일하게 유지한다.
  일반적인 translator 정리와 native scalar/prelude 표현도 유지한다.
  따라서 모든 역사적 성능 개선을 역전시킨 버전이라는 뜻은 아니다.

## 검증 범위

전체 official Wasm suite는 실행하지 않는다. 빌드, 21개 source의 전체 번역,
생성물 재현성 및 Maude 무경고 로드, 목록/record/builtin 경계 검사,
작은 context/host-call/numeric/SIMD 회귀 및 run/modelcheck ingress를 확인한다.
PASS, TIMEOUT, STUCK, 실패를 구분하며 유한 회귀를 의미 보존 증명으로 취급하지 않는다.
실험 입력과 로그는 저장소 밖 `WasmSuiteTest/baseline2-20260917/`에 보관한다.


확인 결과: build 및 21개 source 번역/무경고 load 통과. backend 경계 검사
26개, 종료 guard 검사 3개, 작은 run/modelcheck 예제 통과.
선택 WAST 4개 중 focused/host_calls/official-inline-module 3개 PASS
(완료된 runtime assertion 11개), official-nop 1개 TIMEOUT(30초).
TIMEOUT의 assertion 수는 완료 수로 집계하지 않았고 재시도하지 않았다.
전체 suite 결과나 성능 비교 수치는 아니다.
