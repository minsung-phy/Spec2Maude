# Hint 기능을 제외한 baseline

기준 커밋은 main의 `3c35fafddcbdb811f2cd69c20bee33577bb4a726`이다.
현재 main에서 아래 hint와 종속 코드만 제거한 비교 기준이다.

## 제거·조정 범위

- `k_heatcool`: source의 8개 annotation과 heat/cool·focus·hole 생성 경로 제거.
  해당 규칙은 기존 일반 relation/`RulePr` 번역 경로로 처리한다.
- `maude_sort`, `maude_proper` 및 종속 `maude_subsort`: annotation,
  전용 sort·typed-list·proper 생성 경로 제거. 일반 `SpectecTerminals`와
  `seq(...)` 표현을 사용한다.
- 제거한 hint와 이전 이름 `maude_context`는 위치와 enclosing definition을
  포함한 `Unsupported` 진단으로 거부한다.
- handwritten backend의 생성 타입 참조와 wasm2maude runtime을 일반 목록으로
  맞춘다. WAST의 focus 전용 host-call을 제거하고 일반 host-call을 유지한다.
  modelcheck/harness의 완료 판정에는 명시적 값 검사를 둔다.
- 생성 semantics와 distributed client/server harness를 다시 생성하고
  현재 branch의 문서를 해당 범위에 맞춘다.

## main과 동일하게 유지하는 부분

- 조건 중복 제거 및 일반 조건 정렬.
- iteration helper의 demand 기반 생성, projector 처리 전체.
  `translator/iter.ml`은 main과 byte-for-byte 동일하다.
- `repeatSeq` doubling을 포함한 일반 backend 연산과 builtin 구현.
- wasm2maude 인코딩, CLI 구조, 출력 분할과 나머지 정확성 수정.

따라서 모든 최적화를 제거한 baseline이라는 의미는 아니다.
기존 조건 정렬을 사용하므로 source premise의 문자 그대로의 평가 순서를
보장하거나 일반 의미 보존을 증명했다고 주장하지 않는다.

## 검증

```sh
dune build
dune exec bin/spec2maude.exe --
bash test/spectec_to_maude.sh
python3 test/baseline.py
```

집중 실행 검증 입력과 로그는 저장소 밖
`/private/tmp/spec2maude-baseline-narrow-evidence/`에 기록한다.
확인한 결과:

- build, 21개 source 생성물 재현성, Maude 무경고 load: PASS.
- 제거 hint 5종의 위치 포함 거부와 일반 relation 실행: PASS.
- run/harness: 반환값 7 확인.
- modelcheck: 8 states에서 7 도달, 8 미도달; 7의 eventual return과 8의
  반환 금지 true, 8의 eventual return은 예상한 counterexample.
- 작은 WAST: 일반 실행 4개와 host-call 1개 assertion PASS.
- 완료 판정 10개 probe와 유효한 빈 명령열의 Step 종료 검사: PASS.

modelcheck의 사전 rewrite/search bound는 1000이고 전체 process timeout은
60초다. WAST는 steps 10000, call-depth 32, timeout 45초다.
완료 판정은 search depth 1과 timeout 15초로 확인했다.
전체 official Wasm suite와 distributed 모델 전체 탐색은 실행하지 않았다.
