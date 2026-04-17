# Maude 로드 Warning/Advisory 분석 (연구 재개용)

> 작성일: 2026-04-17
> 대상: `output.maude` 단독 로드, `wasm-exec.maude` 로드
> 목적: 경고의 패턴/원인/영향/해결 우선순위를 정량적으로 고정

---

## 1. 분석 질문

이 문서는 다음 질문에 답한다.

1. `load output` 및 `load wasm-exec` 시 경고/권고가 정확히 몇 건 발생하는가?
2. 어떤 경고가 구조적(번역기 설계) 문제이고, 어떤 경고가 모듈 구성(임포트/오버로드) 문제인가?
3. 어떤 경고가 의미 보존(soundness)에 실질적 위험을 주는가?
4. 어떤 순서로 고치면 연구 재개 시 리스크를 가장 빨리 낮출 수 있는가?

---

## 2. 재현 프로토콜

### 2.1 실행 환경

- Maude: `/Users/minsung/Dev/tools/Maude-3.5.1-macos-x86_64/maude`
- 프로젝트 루트: `Spec2Maude/`

### 2.2 로그 수집 커맨드

```bash
MAUDE_BIN=/Users/minsung/Dev/tools/Maude-3.5.1-macos-x86_64/maude

printf "load output\nquit\n" \
  | "$MAUDE_BIN" > /tmp/spec2maude_load_output.log 2>&1

printf "load wasm-exec\nquit\n" \
  | "$MAUDE_BIN" > /tmp/spec2maude_load_wasm_exec.log 2>&1
```

### 2.3 1차(라인 기반) 카운트

```bash
grep -c '^Warning:'  /tmp/spec2maude_load_output.log
grep -c '^Advisory:' /tmp/spec2maude_load_output.log
grep -c '^Warning:'  /tmp/spec2maude_load_wasm_exec.log
grep -c '^Advisory:' /tmp/spec2maude_load_wasm_exec.log

grep -c 'multiple distinct parses' /tmp/spec2maude_load_output.log
grep -c 'multiple distinct parses' /tmp/spec2maude_load_wasm_exec.log

grep -c 'used before it is bound' /tmp/spec2maude_load_output.log
grep -c 'used before it is bound' /tmp/spec2maude_load_wasm_exec.log
```

### 2.4 2차(Warning block 기반) 카운트

주의: `variable I is used` + 다음 줄 `before it is bound`처럼 phrase가 줄 경계에서 끊기는 케이스가 있어 line grep이 1건 낮게 잡힐 수 있다.

---

## 3. 정량 요약

### 3.1 전체 통계

| 로드 대상 | Warning | Advisory | multiple distinct parses | used before it is bound (line grep) | severe marker* |
|---|---:|---:|---:|---:|---:|
| `output.maude` | 137 | 9 | 34 | 102 | 0 |
| `wasm-exec.maude` | 139 | 13 | 34 | 104 | 0 |

* severe marker: `Fatal error`, `stack overflow`, `parse error`, `counterexample`, `deadlock`.

### 3.2 block 파싱 보정치

- `output.maude`: `used-before-bound` 103 warning block
- `wasm-exec.maude`: `used-before-bound` 105 warning block

line grep 대비 +1 차이는 줄 경계 분리(`is used` / `before it is bound`) 포맷 때문이다.

### 3.3 기여도(Warning만 기준)

- `output.maude`
  - `used-before-bound`: 약 74.5% (102/137)
  - `multiple distinct parses`: 약 24.8% (34/137)
- `wasm-exec.maude`
  - `used-before-bound`: 약 74.8% (104/139)
  - `multiple distinct parses`: 약 24.5% (34/139)

즉, 현재 경고의 대부분은 "변수 바인딩 순서/존재" 문제다.

### 3.4 `wasm-exec` 추가분 분해

- Warning 증가: `+2` (모두 `MC-I` 관련)
- Advisory 증가: `+4`
  - `_[_<-_]` import 충돌 2건 (`WASM-EXEC`, `WASM-FIB`)
  - `State` sort 이중 import 1건 (`WASM-FIB-PROPS`)
  - `_[_<-_]` import 충돌 1건 (`WASM-FIB-PROPS`)

해석: `wasm-exec` 자체는 신규 경고를 크게 만들지 않으며, 경고의 본체는 `output.maude`에서 이미 형성된다.

---

## 4. 패턴 Taxonomy

### 4.1 W1: `multiple distinct parses` (34건)

### 대표 예시

```text
Warning: "output.maude", line 3730: multiple distinct parses
eq $shift-labelidxs((SHIFT2-LABELIDX SHIFT2-LABELIDXQ)) = ...
```

```text
Warning: "output.maude", line 4291: multiple distinct parses
ceq Memtype-ok(...) = true if Limits-ok(..., (2 ^ ($size(...) - 16))) = true ...
```

```text
Warning: "output.maude", line 5008: multiple distinct parses
ceq $signed(SIGNED0-N, SIGNED0-I) = SIGNED0-I if ((SIGNED0-I < (2 ^ (SIGNED0-N - 1)))) = true .
```

### 구조적 원인

- mixfix/infix 연산자 조합(`^`, `-`, `<`, `<=`, list concat)의 우선순위/결합성이 명시적 괄호보다 약한 위치에서 겹침
- 일부 식이 토큰열 기반으로 생성되면서 parser가 복수 parse tree를 허용

### 영향

- 즉시 실패는 아니지만, parser 비용 증가 및 해석 일관성 위험 존재
- 후속 리팩터링 시 동일 입력이 다른 parse 경로로 해석될 가능성

---

### 4.2 W2: `variable ... used before it is bound` (지배적)

### 대표 예시 A (Validation 관계)

```text
Warning: "output.maude", line 4133: variable SUBTYPE-OK-R00-COMPTYPEQ is used before it is bound
ceq Subtype-ok(...) = true if ... /\
  $unrolldt(...) == CTORSUBA3(..., SUBTYPE-OK-R00-COMPTYPEQ) = true /\
  Comptype-sub(..., SUBTYPE-OK-R00-COMPTYPEQ) = true ...
```

### 대표 예시 B (기초 타입 판정)

```text
Warning: "output.maude", line 2107: variable I is used before it is bound
ceq type-ok(T, uN(N)) = true if I <= 2 ^ N - 1 and I >= 0 = true .
```

### 대표 예시 C (치환 헬퍼)

```text
Warning: "output.maude", line 3010: variable SUBST0-I is used before it is bound
eq $subst-all-valtype(SUBST0-T, SUBST0-TU) = $subst-valtype(SUBST0-T, CTORWIDXA1(SUBST0-I), SUBST0-TU) .
```

### 대표 예시 D (`wasm-exec` 고유 2건)

```text
Warning: "wasm-exec.maude", line 236: variable MC-I is used before it is bound
ceq mc(< MC-Z | MC-IS >) |= result-neg = true
  if MC-IS = CTORCONSTA2(CTORI32A0, MC-I) /\ MC-I < 0 .
```

### 구조적 원인 (핵심)

1. **관계 전제의 구성적 바인딩 손실**
- SpecTec에서 패턴을 통해 값을 "꺼내는" 전제가 Maude에서는 단순 Bool test(`... = true`)로 직렬화되는 경우가 있음
- 이때 전제 내부 패턴 변수는 "값을 생성/바인딩"하지 못해 unbound 경고로 남음

2. **RHS-only 변수 생성**
- 일부 `eq`에서 변수가 LHS/조건에 나타나지 않고 RHS에만 나타남 (`SUBST0-I`류)
- 실행 관점에서 해당 변수는 입력으로 고정되지 않아 경고 유발

3. **전제 스케줄러 fallback**
- `schedule_prems`의 강제 emit 경로에서 아직 바인딩되지 않은 항을 Bool 조건으로 밀어 넣는 경우가 남아 있음

### 영향

- 파서 경고보다 위험도가 높다.
- 비실행 영역(특히 validation/typing)에서 의미 보존 회귀 가능성이 존재한다.
- 현재 smoke/modelCheck가 통과하는 이유는 실행 경로가 제한적이기 때문이지, 전체 규칙군이 경고-무관함을 의미하지 않는다.

---

### 4.3 A1: `all the variables in ... := ... are bound before matching` (8건)

### 예시

```text
Advisory: line 3424..3430: CTORSA0 := SX1
Advisory: line 3479: $vsize(VECTYPE) quo 2 := SZ1 * M1
```

### 해석

- `:=` 좌변이 이미 바인딩된 상태라 assignment fragment가 매칭 바인딩을 제공하지 않음
- 의미 오류보다는 번역기 조건 생성의 비최적화 신호

---

### 4.4 A2: `_[_<-_]` import 충돌 (`no common ancestor`)

### 예시

```text
Advisory: operator _[_<-_] has been imported from both
"pretype.maude", line 83 and line 84 with no common ancestor.
```

### 구조적 원인

- `DSL-RECORD`에서 `_[_<-_]`가
  - `(WasmTerminals, Nat, WasmTerminal)`
  - `(WasmTerminals, WasmTerminal, WasmTerminal)`
  두 시그니처로 오버로드됨
- 모듈 import 시점에 두 중간 소트 계층의 공통 상위 관계가 명시되지 않아 advisory 발생

### 영향

- 즉시 실패는 아니지만 오버로드 해석 안정성 저하 요인

---

### 4.5 A3: `sort State has been imported from both ...` (wasm-exec 1건)

### 예시

```text
Advisory: "wasm-exec.maude", line 193 (mod WASM-FIB-PROPS): sort State has been
imported from both "model-checker.maude" ... and "output.maude" ...
```

### 해석

- `MODEL-CHECKER`의 `State`와 `SPECTEC-CORE`의 `State` 이름 충돌
- 현재 실험은 동작하지만, 장기적으로는 모듈 경계 명확화가 필요

---

## 5. 심각도/우선순위 매트릭스

| ID | 건수(기준) | 위험도 | 연구 영향 | 우선순위 |
|---|---:|---|---|---|
| W2 used-before-bound | 102 (line) / 103 (block) | 높음 | 의미 보존 주장 약화 가능 | P0 |
| W1 multiple parses | 34 | 중간 | 재현성/해석 안정성 저하 | P1 |
| A2 import 충돌 `_[_<-_]` | 1 (output), 4 (wasm load 포함) | 중간 | 모듈 해석 취약점 누적 | P1 |
| A1 redundant assignment advisory | 8 | 낮음~중간 | 코드 품질/유지보수성 저하 | P2 |
| A3 `State` 이중 import | 1 (wasm) | 낮음~중간 | 장기 모듈화 리스크 | P2 |

---

## 6. 원인-해결 매핑 (실행 가능한 작업 단위)

### 6.1 단기 (1-2일)

1. `wasm-exec.maude`의 `MC-I` 2건 제거
- `result-neg` 전제를 바인딩 친화적으로 분해
- 기대효과: `load wasm-exec` Warning 2건 즉시 감소

2. Warning 집계 스크립트 고정
- line grep + block 파싱을 모두 저장
- 줄 경계 분리 케이스를 자동 보정

### 6.2 중기 (1-2주)

1. `translator.ml` 전제 생성기 보강 (`schedule_prems` 계열)
- 바인딩 생성 가능한 전제를 Bool test로 고정하지 않도록 분류 강화
- 강제 fallback emit 최소화

2. RHS-only 변수 탐지 규칙 추가
- `eq/ceq` 생성 직전, RHS-only 변수 존재 시
  - 인자 승격(함수 인자로 올리기) 또는
  - 의도된 existential이면 명시적 binding fragment로 변환

3. `multiple parse` 저감 패치
- 산술/비교/논리 조합 생성 시 괄호 정책 강화
- 불가피한 mixfix는 우선순위 명시 또는 prefix helper 사용

### 6.3 장기 (3-4주)

1. 소트/연산자 namespace 정리
- `State` 충돌과 `_[_<-_]` 오버로드 충돌 해소
- DSL 계층에서 공통 상위 소트 관계를 명시하거나 연산자명 분리

2. 경고 예산(warning budget) 정책 도입
- P0 경고(`used-before-bound`) 0건 목표
- P1 경고(`multiple parse`) 단계적 감축 목표

---

## 7. 검증 게이트 (Artifact KPI)

논문/발표 재개 전 최소 게이트:

1. 기능 게이트
- `./scripts/regen_and_smoketest.sh current` 통과
- fib + 3 benchmark 모델체킹 true 유지

2. 정적 품질 게이트
- severe marker 0 유지
- `used-before-bound`:
  - 단기 목표: 증가 금지(non-increasing)
  - 최종 목표: 0
- `multiple distinct parses`:
  - 단기 목표: 34 -> 20 이하
  - 중기 목표: 0

3. 재현 게이트
- 경고 집계 리포트(`raw log`, `line count`, `block count`)를 artifacts에 함께 저장

---

## 8. Threats to Validity

1. 현재 정량은 "load 시점" 기준이다.
- rewrite/modelCheck 경로에서 실제로 활성화되는 규칙군은 부분집합일 수 있다.

2. line grep만 쓰면 과소계수 가능성이 있다.
- phrase 줄분할 케이스로 인해 1건 차이가 생길 수 있다.

3. 경고 제거가 곧 의미 보존 증명은 아니다.
- 경고 0은 필요조건에 가깝고 충분조건은 아니다.
- 별도의 등가성/회귀 테스트가 병행되어야 한다.

---

## 9. 연구 재개용 체크리스트

1. Warning taxonomy 표와 카운트가 최신 로그와 일치하는가?
2. `wasm-exec` 고유 경고(+2)가 제거되었는가?
3. `translator.ml` 수정 후 `used-before-bound`가 감소했는가?
4. smoke/modelCheck 결과가 회귀 없이 유지되는가?
5. 문서/CSV/원문 근거가 모두 저장되어 artifact 패키징 가능한가?

---

## 10. 관련 문서

- 번역 규칙/설계: `docs/Translation_Rules.md`
- 실행/검증 결과: `docs/execution_results.md`
- wasm 3.0 규칙 커버리지: `docs/wasm3_pattern_coverage.md`
- 미변환 규칙 원문: `docs/wasm3_not_translated_rules.txt`
- 패턴 상태 CSV: `docs/wasm3_rule_pattern_status.csv`
