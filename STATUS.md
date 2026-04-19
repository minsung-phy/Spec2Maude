# Spec2Maude — 현재 상태 / 문제점 / 할일

작성일: 2026-04-19

---

## 1. 잘한 점 (이미 된 것)

### 번역기 (translator.ml)
- SpecTec IL AST → Maude 변환 파이프라인 동작
- TypD 처리 (AliasT/StructT/VariantT) → sort membership / hasType 기반 WellTyped
- DecD/DefD → Maude eq/ceq 함수식
- RelD 4 패턴 확립 (`labmeeting.md` 참조)
  1. 일반 판정 RelD → `cmb ... : ValidJudgement`
  2. Step-pure → `ceq step(< Z | VALS instr IS >) = ...`
  3. Step-read → 상태 z 유지하며 읽기
  4. Step → z → z' 상태 변화
- `$rollrt` 하드코딩 브릿지 제거 (commit `11c341b`)

### 실행 인프라 (wasm-exec.maude)
- 손수 작성한 eval-context 규칙 (label/frame/handler/loop)
- WASM-FIB 모듈 (fib-config, fib-body, fib-loop-body)
- 모델체킹 설정 (`result-is`, `trap-seen` atomic props)
- `modelCheck(fib-config(i32v(5)), <> result-is(5))` 실행 자체는 가능 (결과는 아래 문제점 참조)

### 산출물
- `output.maude` 7,200여 줄 자동 생성
- 랩미팅용 패턴 설명 문서 `labmeeting.md` 작성

---

## 2. 현재 문제점

### ✅ P0-0. Step rule rl/crl 전환 완료
- 통합 전략은 유지했다. 기준은 `translator.ml`이고, `translator_0417.ml`에서 **Step rl/crl 생성 경로**와 **context heating/cooling 경로**만 선택 이식했다.
- 현재 `translator.ml`은 `Step` / `Step-pure` / `Step-read`를 `rl/crl`로 생성한다.
- `step`은 이제 `op step : ExecConf -> ExecConf [frozen (1)] .` 로 생성되어 top-most 1-step 통제가 작동한다.
- 실행을 막던 translator 쪽 병목도 함께 수정했다.
  - `Idx` 계열 `Int` bridge overload 제거 (`$local/$global/... : State Int -> ...` 제거)
  - `Nat < Idx/Localidx/...` subsort 추가
  - 잘못된 generic `heat-step-ctxt-instrs` / `cool-step-ctxt-instrs` 제거
- 유지한 제약:
  - RelD Bool 반환 체계로 회귀 안 함
  - type-ok 체계로 전체 전환 안 함
  - rollrt 특수 브리지 재도입 안 함

### ✅ P0-A. fib rewrite / modelCheck 통과
- 검증 결과:
  - `rewrite [10000] in WASM-FIB : steps(fib-config(i32v(5))) .`
    - 종료
    - 최종 결과 핵심: `CTORCONSTA2(CTORI32A0, 5)`
  - `red in WASM-FIB-PROPS : modelCheck(fib-config(i32v(5)), <> result-is(5)) .`
    - `result Bool: true`
  - `red in WASM-FIB-PROPS : modelCheck(fib-config(i32v(5)), [] ~ trap-seen) .`
    - `result Bool: true`
- 디버깅 과정에서 실제 원인으로 확인된 translator 문제:
  - `$local` lookup이 값으로 끝나지 않고 `index(..., CTORWIDXA1(...))`에 남는 문제
  - `step` 내부에서 `exec-step`가 다시 발화해 `step(step(...))`가 생기는 문제
  - generic `instrs` heating이 `CONST BRIF` 같은 이미 redex인 조각을 잘못 분해하는 문제
- 위 3개는 모두 `translator.ml` 수정 후 해결됐다.

### P0-B. V128 stack overflow (WIP 브랜치에서 발견)
- 위 P0-A 작업 중, translator의 `type_guard` regex 버그 수정 → `cmb T : V128 if true` 가 `cmb T : V128 if (T hasType (vN(128))) : WellTyped` 로 정상화됨
- 그러나 `output.maude` 2275줄의 `mb (T hasType (vN(N))) : WellTyped .` 가 **무조건** 매칭 → 모든 term이 V128로 취급 → `red step(...)` 시 Maude stack overflow
- 해결 미완. `wip/p0-v128-overflow` 브랜치에 WIP로 저장됨

### P0-C. Maude 경고 다수
- Warning: membership axioms are not guaranteed to work correctly for iterated/associative symbols
  (`s_`, `_+_`, `_*_`, `gcd`, `lcm`, `min`, `max`, `_xor_`, `_&_`, `_|_`, `__`)
- Advisory: `$lsizenn`, `$vsize`, `CTORSA0` 등의 assignment condition에서 LHS 변수가 이미 bound
- 현재는 동작에 직접 영향 없어 보임 (경고만), 하지만 근본적 해결 필요

### P1. Eval-context 자동 생성 부분 완료
- `translator.ml`이 SpecTec `RulePr` premise에서 label/frame/handler context용 heat/cool을 자동 생성한다.
- 현재 유지되는 자동 생성 경로:
  - label context
  - frame context
  - handler context
- 제거한 자동 생성 경로:
  - generic `instrs` context heat/cool
  - 이유: fib 실행에서 잘못된 분해를 일으켜 `restore-instrs(step(...))`에 멈췄고, 이는 의미 보존보다 회귀를 만들었다.
- `wasm-exec.maude`의 수동 context rule 일부는 여전히 남아 있다. 완전 제거는 후속 정리 항목이다.

### P2. 범위 검증 미실시
- fib 외 다른 예제 (factorial, 재귀 call, memory op 등) 미테스트
- translator가 SpecTec rule **몇 개** 중 **몇 개** 번역하는지 수치 미측정
- `fib(0)` ~ `fib(5)`를 각각 개별 실행해 수열을 표로 남기는 작업도 아직 안 했다

---

## 3. 할일 리스트 (우선순위순)

### 즉시 (다음 세션 1회)
- [x] 선택 통합 1단계: `translate_step_reld`를 rl/crl 기반으로 전환
- [x] 선택 통합 2단계: context 규칙 자동 생성 경로(`is_ctxt_rule`, `try_decode_ctxt_conclusion`, heat/cool) 이식
- [x] 통합 제외 항목 고정: RelD Bool 반환, type-ok 체계, rollrt 특수 브리지
- [x] **P0-0 재설계**: Step/Step-pure/Step-read 번역을 `rl/crl` 로 이행
- [x] fib `rewrite` / `modelCheck` 재검증
- [ ] `fib(0)` ~ `fib(5)`를 각각 개별 실행해 기대 수열 확인
- [ ] `STATUS.md` 기준 warning 목록화 및 분류
- [ ] **P0-B 디버그**: `wip/p0-v128-overflow` 브랜치에서
  - `output.maude:2275`의 `mb (T hasType (vN(N))) : WellTyped .` 가 왜 무조건인지 추적
  - T의 sort 확인 (아마 kind 레벨로 너무 넓음)
  - translator가 이 mb를 어느 SpecTec 규칙에서 어떻게 생성하는지 로그 추가
  - 해결책: (a) mb에 `T : SomeNarrowerSort` 조건 추가, (b) V128 cmb를 `owise`로, (c) hasType 시스템 재설계
- [ ] **커밋** (작성자 `minsung-phy`, Claude 공저자 표시 없음)

### 단기 (1-2 세션)
- [ ] P0-C 경고 체계적으로 해결 또는 suppress 근거 문서화
- [ ] translator 커버리지 수치: SpecTec 전체 rule 수 vs 자동 번역 성공 수
- [ ] "translator가 번역 못 하는 규칙" 목록화 및 원인 분석
- [ ] `wasm-exec.maude`에 남아 있는 수동 override와 자동 생성 경로를 다시 정리

### 중기 (1-2 주)
- [ ] P1 후속: eval-context 자동 생성 정리
  - label/frame/handler 자동 생성 경로와 `wasm-exec.maude` 수동 rule의 중복 제거
  - `instrs` context는 어떤 제약 아래서만 안전한지 재설계
- [ ] fib 외 예제 확장 (factorial, recursive call)
- [ ] memory ops, table ops 지원 범위 확인

### 장기 (논문/발표 준비)
- [ ] 벤치마크 표 (각 예제별 실행 시간, 자동 번역 비율)
- [ ] Translator 아키텍처 설명 문서 (현재는 `labmeeting.md`의 4 패턴이 전부)
- [ ] SpecTec ↔ Maude semantic preservation 논증

---

## 4. 브랜치 상태

| 브랜치 | 상태 | 비고 |
|--------|------|------|
| `main` | fib modelCheck deadlock | 최종 커밋 `11c341b` |
| `wip/p0-v128-overflow` | step() stack overflow | P0 WIP 저장, 재개 시 여기서부터 |

---

## 5. 다음 세션 진입점

1. `fib(0)` ~ `fib(5)`를 각각 `steps(...)`로 돌려 실제 결과 표를 남긴다
2. warning/advisory를 유형별로 묶는다
3. `wip/p0-v128-overflow` 브랜치의 V128 이슈를 다시 재개한다
