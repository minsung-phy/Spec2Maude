# 2026-09-18 미팅 결정

사용자가 전달한 미팅 결정을 기록한다. 기존 1·2·3·4번 개발 계획과 실행 순서는 전부 철회한다.
`PERFORMANCE_DEVELOPMENT_PLAN.md`는 삭제했다. 과거 실험 사본·수치·로그는 역사적 근거로만 남기며,
현재 개발 방향이나 채택된 구현으로 취급하지 않는다.

## 1. 성능 판단은 Maude profiling으로

- fib의 rewrite 횟수 자체를 더 줄이는 것을 목표로 삼지 않는다.
- 실제 병목과 불필요한 비용을 Maude profile로 확인하고 제거한다.
- 기본 사용 순서는 아래와 같다. 정확한 출력 의미와 측정 조건은 `reference/manual/`의 Maude manual을 확인한다.

```maude
set profile on .
--- 측정할 명령 실행
show profile .
```

전체 rewrite 수나 작은 진단의 속도만으로 병목 원인·전체 suite 성능을 단정하지 않는다.

## 2. mayPure/mayRead 대신 context heating/cooling

- `mayPure`, `mayRead`로 검색을 걸러내는 기존 guard 계획은 채택하지 않는다.
- `Step/ctxt-instrs`에서 사용한 heating/cooling 방식을 기준으로 한다.
- 같은 방식으로 `hint(k_heatcool)`를 부여하고 `identifyPure`, `identifyRead`를 사용한다.
- 2026-09-21 사용자 지시에 따라 기존 hint 이름 `maude_context`를 `k_heatcool`로 변경했다.
- 이 이름들은 미팅에서 정한 설계 방향이다. 구체적인 생성 규칙과 hint 계약은 실제 IL/source를 따라 구현한다.

## 3. 적용 범위는 premise에 ~>가 있는 모든 source rule

- SpecTec source rule의 premise에 `~>`가 있으면 모두 heating/cooling으로 번역하는 것을 개발 기준으로 한다.
- 일부 LABEL/FRAME/HANDLER 규칙만 대상으로 하는 이전 4번 범위로 제한하지 않는다.
- 실제 relation 선언과 IL `RulePr`에서 해당 premise를 식별한다. Wasm 이름을 하드코딩하지 않는다.
- premise 순서·변수 binding·다중 premise·가능한 결과·source Step 경계를 유지하도록 계약과 번역을 정한다.
  지원이 미완료된 형태를 조용히 건너뛰거나 기존 계획으로 대체하지 않는다.

## 4. 메모리 트리는 나중에; 현재는 find 방식과 profile

- 메모리 이진트리 표현은 아주 나중 과제로 미룬다. 먼저 high-level 번역 방법론을 완성한다.
- 현재 메모리에서 값을 찾는 구현을 조사하고, 함수형 순회 알고리즘을 그대로 옮기는 대신
  Maude의 matching을 이용한 `find` 방식으로 바꾼다.
- 미팅에서 제시한 설명용 형태:

```maude
find(IL :: t :: IL') = true .
find(IL) = false [owise] .
```

이는 matching을 활용하라는 설계 예시이며 그대로 로드할 완성 코드가 아니다.
실제 찾을 대상의 전달/binding, 목록 연산자의 속성, source 연산이 요구하는 위치·결과를 확인해 구체화한다.
값의 포함 여부와 주소에 의한 조회를 혼동하여 source 의미를 바꾸지 않는다.
변경 뒤에도 병목이 있으면 Maude profile로 위치와 수치를 확인한다.

## 5. IL에 없는 구현 선택은 interpreter를 따르지 않는다

- 의미의 근거는 SpecTec IL과 적용되는 formal/source 정의다.
- `drop`처럼 IL에서 규정하지 않은 구현 helper나 순회 방법은 SpecTec interpreter를 모방하지 않는다.
- 필요한 의미를 Maude 스타일의 matching·equation·rule·native operation으로 구현한다. `find`가 그 예다.
- IL이 명시한 의미를 지우거나 새로운 의미를 넣으라는 뜻은 아니다.

이 원칙은 루트 `AGENTS.md`에도 반영한다.

## 이번 변경 범위

기존 계획 삭제, 미팅 결정 기록, 작업 지침 및 기억 갱신이다.
translator/backend 코드를 수정하거나 profile·suite를 새로 실행한 것은 아니다.
기존 실험·결과 파일을 삭제하거나 진행 중인 사용자 실행을 제어하지 않는다.
