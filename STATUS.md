# Spec2Maude — 현재 상태 / 문제점 / 할일

작성일: 2026-04-18

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

### ⚠ P0-0. [근본 설계 이슈] Step rule 을 eq/ceq 로 번역 중 (교수님 요구 §2.2 위반)
- 통합 전략: P0-0 해결은 파일 전체 교체가 아니라 선택 통합으로 진행한다. 기준은 translator.ml이며, translator_0417.ml에서 rl/crl 기반 Step 생성과 context heating/cooling 경로만 이식한다. Bool 중심 RelD, type-ok 전환, rollrt 특수 브리지는 보류하고 별도 검증 항목으로 분리한다.
- 현재 `translator.ml` 은 `Step` / `Step-pure` / `Step-read` relation 을 모두 **`eq` / `ceq` (equational)** 로 내려보냄.
- 근거: [meeting/0331 개인.txt](meeting/0331%20개인.txt) 24:03, 24:55, 27:04
  - "스펙텍과 리라이팅 로직의 룰의 모양이 비슷해 보이지만 시멘틱스가 완전히 다르다"
  - "스텝 펑션을 프로즌으로 정리하면 ... 스텝이 무조건 붙어야만 리라이팅 룰 트랜지션이 일어나니까"
  - "이 스펙텍 룰을 그냥 eq 로 바꾸는 거랑 틀렸다" (그냥 rl 로 바꾸는 것도 주의 필요)
- 교수님이 의도한 형태:
  ```maude
  crl [step-…] :
    step(< Z | LHS-instrs >) => step(< Z' | RHS-instrs >)
    if …conditions… .
  ```
  (step 래퍼 아래의 **rl/crl** — rewriting rule. 1 rewrite = 1 step.)
- 영향: P0-A (fib deadlock) / P0-B (V128 stack overflow) 보다 **상위 설계 결함**. eq/ceq 는 confluence 요구 + 임의 서브텀에서 매칭될 수 있어 의미론 보존 측면에서 부적절.
- **우선순위 최상.** 이거 해결되면 P0-A, P0-B 의 증상도 다르게 나올 가능성 있음.

### P0-A. fib 모델체킹이 deadlock
- `modelCheck(fib-config(i32v(5)), <> result-is(5))` → counterexample(nil, ... deadlock)
- 초기 state에서 rule이 fire되지 않음
- 원인 가설: LOCAL.SET/TEE/GLOBAL.SET의 Step rule이 "스택에 이미 값이 쌓인" 상태를 매칭하지 못함
  (스택: `VAL1 VAL2 (LOCAL.SET x)` 같은 경우 rule LHS의 `val (LOCAL.SET x)` 매칭 실패)
- 해결 시도: Step-pure/Step/Step-read rule LHS/RHS에 `VALS` prefix 변수 + `all-vals(VALS)=true` 가드 추가 → 별도 브랜치 `wip/p0-v128-overflow`에 WIP 커밋됨

### P0-B. V128 stack overflow (WIP 브랜치에서 발견)
- 위 P0-A 작업 중, translator의 `type_guard` regex 버그 수정 → `cmb T : V128 if true` 가 `cmb T : V128 if (T hasType (vN(128))) : WellTyped` 로 정상화됨
- 그러나 `output.maude` 2275줄의 `mb (T hasType (vN(N))) : WellTyped .` 가 **무조건** 매칭 → 모든 term이 V128로 취급 → `red step(...)` 시 Maude stack overflow
- 해결 미완. `wip/p0-v128-overflow` 브랜치에 WIP로 저장됨

### P0-C. Maude 경고 다수
- Warning: membership axioms are not guaranteed to work correctly for iterated/associative symbols
  (`s_`, `_+_`, `_*_`, `gcd`, `lcm`, `min`, `max`, `_xor_`, `_&_`, `_|_`, `__`)
- Advisory: `$lsizenn`, `$vsize`, `CTORSA0` 등의 assignment condition에서 LHS 변수가 이미 bound
- 현재는 동작에 직접 영향 없어 보임 (경고만), 하지만 근본적 해결 필요

### P1. Eval-context 규칙이 손수 작성됨
- `wasm-exec.maude` 177-250줄의 label/frame/handler/loop context 규칙
- translator가 SpecTec RulePr premise에서 자동 생성해야 함

### P2. 범위 검증 미실시
- fib 외 다른 예제 (factorial, 재귀 call, memory op 등) 미테스트
- translator가 SpecTec rule **몇 개** 중 **몇 개** 번역하는지 수치 미측정

---

## 3. 할일 리스트 (우선순위순)

### 즉시 (다음 세션 1회)
- [ ] 선택 통합 1단계: translate_step_reld를 rl/crl 기반으로 전환
- [ ] 선택 통합 2단계: context 규칙 자동 생성 경로(is_ctxt_rule, try_decode_ctxt_conclusion, heat/cool) 이식
- [ ] 통합 제외 항목 고정: RelD Bool 반환, type-ok 체계, rollrt 특수 브리지
- [ ] **P0-0 재설계 (최우선)**: Step/Step-pure/Step-read 번역을 `rl/crl` 로 이행
  - `translator.ml` 의 `translate_step_reld` 수정: `ceq step(LHS) = RHS if cond` → `crl step(LHS) => step(RHS) if cond`
  - 단순 규칙 (프리미스 없음) 은 `rl step(LHS) => step(RHS) .`
  - wasm-exec.maude 의 step 선언 / 구동 harness 도 함께 조정 (eq 재작성 아닌 rl 재작성에 맞게)
  - 결정: step 래퍼가 RHS 에도 남는지 (propagating) vs 1 rewrite 후 빠지는지 (one-shot) 미팅에서 확인 필요. 일단 propagating 으로 가정.
  - 이 재설계 완료 후에야 P0-A, P0-B 가 원래 문제인지 재평가 가능.
- [ ] **P0-B 디버그**: `wip/p0-v128-overflow` 브랜치에서
  - `output.maude:2275`의 `mb (T hasType (vN(N))) : WellTyped .` 가 왜 무조건인지 추적
  - T의 sort 확인 (아마 kind 레벨로 너무 넓음)
  - translator가 이 mb를 어느 SpecTec 규칙에서 어떻게 생성하는지 로그 추가
  - 해결책: (a) mb에 `T : SomeNarrowerSort` 조건 추가, (b) V128 cmb를 `owise`로, (c) hasType 시스템 재설계
- [ ] **P0-A 재검증**: P0-B 풀린 후 `rew` 와 `modelCheck` 둘 다 통과 확인
  - fib(1), fib(2), fib(3), fib(5) 순서로
  - `rew` 먼저 (빠름), 그 다음 `modelCheck`
- [ ] **커밋** (작성자 `minsung-phy`, Claude 공저자 표시 없음)

### 단기 (1-2 세션)
- [ ] P0-C 경고 체계적으로 해결 또는 suppress 근거 문서화
- [ ] translator 커버리지 수치: SpecTec 전체 rule 수 vs 자동 번역 성공 수
- [ ] "translator가 번역 못 하는 규칙" 목록화 및 원인 분석

### 중기 (1-2 주)
- [ ] P1: eval-context 자동 생성
  - SpecTec RulePr premise 파싱 로직 추가
  - `wasm-exec.maude:177-250` 손수 규칙 제거 후 재검증
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

1. `git checkout wip/p0-v128-overflow`
2. `output.maude:2275` 의 `mb (T hasType (vN(N))) : WellTyped .` 확인
3. `translator.ml` 에서 이 mb 생성 지점 찾기 (`grep "hasType" translator.ml`)
4. mb에 조건 추가 또는 V128 cmb를 `owise` 처리
5. `red step(< fib-state | 10-instr body >)` 가 stack overflow 없이 끝나는지 확인
6. fib(1) → fib(5) 순서로 `rew`, `modelCheck` 검증
