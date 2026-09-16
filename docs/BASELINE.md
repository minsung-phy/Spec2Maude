# baseline2: 직접 재귀 번역 기준

출발점은 `main`의 `30aeb73e45f064c7cc755f9a38620bb5c7d22b14`이다.
기존 `baseline` (`cb10d39`)과 `main` ref는 변경하지 않는다.
기존 baseline 이후의 오류 수정을 유지하고, 아래 실행 최적화와 그 생성 코드를
제거했다. source AST와 premise를 직접 따라가는 비교 기준이다.

## 제거한 최적화

- `maude_sort`, `maude_subsort`, `maude_proper`, `maude_context` source hint와
  OCaml 구현(`Hintd`, typed-list 생성, context focus/heat/cool 변환)을 제거했다.
  이 hint를 새 입력에 쓰면 위치를 포함한 Unsupported 진단으로 거부한다.
- 모든 목록은 `SpectecTerminals`, `eps`, `__`, nested `seq(...)`를 사용한다.
  context도 source의 일반 relation rule과 premise로 번역한다.
- backend의 memo, cursor, 32개 단위 순회, doubling, 압축 `runSeq`,
  splice 전용 순회, record lookup fallback/field forwarding 단축을 제거했다.
- builtin native power 치환, binary digit logarithm, UTF-8 tail 검사 생략을
  제거했다. 단순 재귀와 원래 검사를 사용한다.
- 중복 source premise 제거와 iteration helper의 mutable demand 기반 생성 생략을
  제거했다. premise 순서·중복을 유지하며 projector의 forward 재검사를 복원했다.
- WAST focus 전용 host-call rule과 memo 초기화 명령을 제거했다.

## 보존한 정확성 수정과 지원

- relation 입력 구조, 변수 freshness·binding·type capture, alias/type guard,
  `otherwise`의 AU 목록 overlap, inverse forward 검사, nested-list boxing을 유지한다.
- slice/update의 범위 밖 실패, option 합성의 부분성, `$fbits_` inverse,
  DET NaN, subtype bottom 처리를 유지한다. backend 파일 전체를 과거로 돌리지 않는다.
- Nat/Int/Rat는 native exact 연산을 사용한다. Rat의 음수 정수 지수는 정의역
  검사를 포함한 작은 `ratPow`로 처리한다. 유한 Real literal과 이들에서 닫힌
  유리수 값 산술은 별도 `realValue(Rat)`로 정확하게 표현한다. 0 나눗셈과
  잘못된 정수 변환은 값이 되지 않는다. IEEE Float 근사로 대체하지 않는다.
- 매개변수화 record 합성은 적용된 필드 타입을 따라 재귀 번역한다.
  무인자 record는 기존 선언별 합성 방정식을 사용한다.
- `IfE`, root `UpdE`, 실제 type argument와 iteration 조건을 유지한다.
- `builtin`, `inverse`, `maude_rule` 등 기존 비직접 경계의 명시적 계약은
  [HINT_CONTRACTS.md](HINT_CONTRACTS.md)에 남는다.
- run/modelcheck 결과 guard와 일반 host-call argument 검사, harness의 오류·timeout
  집계 수정을 유지한다. 출력 균형 괄호와 WAST 64-command 분할도 main과 동일하다.
  후자는 공통 파일 출력 조건이며 source 실행 최적화가 아니다.

## 의미와 한계

여기서 직접 번역은 지원하는 IL 구조와 의미를 보존하도록 구현한다는 기준이다.
목록 encoding, iteration 보조 방정식, 명시적 builtin/inverse 계약은 존재한다.
따라서 source AST와 Maude AST의 문자 그대로의 일대일 대응이나 전체 언어의
isomorphism 증명을 뜻하지 않는다. 기존 Unsupported 경계(예: 표현 변경이 필요한
`SubE` pattern, Real 변환의 inverse pattern)는 명시적으로 남는다.
자세한 적용 범위는 [SEMANTIC_DECISIONS.md](SEMANTIC_DECISIONS.md)를 따른다.

## 확인한 결과

전체 official Wasm suite는 실행하지 않았다.

- build, 21개 source 번역, 생성물 재현성, Maude 무경고 load: PASS.
- backend 경계 26개, 숫자/record/iteration 표현 검사 30개: PASS.
- `otherwise` fallback 차단, 중복 premise 2개 보존, 제거한 hint 거부: PASS.
- 종료 guard 3개와 작은 run/modelcheck 예제: 기대 결과 확인.
- 작은 WAST 3개: PASS, runtime assertion 16개 완료.
- 선택 official 2개: inline-module PASS, nop TIMEOUT(30초).
  main의 같은 nop은 별도 확인에서 PASS(8.920초, runtime assertion 83개)였다.
  timeout 파일의 assertion 수는 완료 수로 세지 않는다.

최종 입력·명령·로그와 변경 분류는 저장소 밖
`WasmSuiteTest/baseline2-20260917/complete/`에 보관한다.
이 결과는 유한 회귀 검증이며 전체 의미 보존 증명이 아니다.
