# Spec2Maude 실행 방법 및 결과

> 작성일: 2026-04-17  

---

## 1. 목적

이 문서는 다음을 한 번에 제공합니다.

- 번역기 실행 방법 (SpecTec -> Maude)
- 자동 스모크 검증 실행 방법 (등식 실행 + LTL 모델체킹)
- 로그 위치와 성공/실패 판정 기준
- 기준 회귀 결과 (current 모드)

---

## 2. 사전 요구사항

- macOS
- OCaml + dune
- Maude 3.5.1 이상
- 프로젝트 루트에서 실행

선택 환경변수:

```bash
export MAUDE_BIN=/Users/minsung/Dev/tools/Maude-3.5.1-macos-x86_64/maude
```

`MAUDE_BIN`을 설정하지 않으면 스크립트가 기본 경로 또는 PATH의 `maude`를 탐색합니다.

---

## 3. 권장 실행 (자동 번역 + 스모크 검증)

### 3.1 current 모드 (연구 결과 보고용 기본)

```bash
./scripts/regen_and_smoketest.sh current
```

동작:

1. `main.exe` 빌드
2. `output.maude` 재생성
3. `wasm-exec.maude` 로드 후 스모크 질의 실행
4. 결과 검증 (`result ExecConf`, `result Bool: true` 개수 등)

### 3.2 auto 모드 (current 실패 시 legacy-safe 폴백)

```bash
./scripts/regen_and_smoketest.sh auto
```

동작:

1. `current` 시도
2. 실패 시 `legacy-safe` 실행
3. `legacy-safe`는 번역 + 로드 sanity만 확인

### 3.3 legacy 모드 (비교/디버그용)

```bash
./scripts/regen_and_smoketest.sh legacy
```

현재 기준으로 `legacy`의 full modelcheck는 deadlock counterexample이 관찰되어 최종 연구 결과 보고에는 부적합합니다.

---

## 4. 수동 실행 절차

자동 스크립트를 쓰지 않을 경우 아래 순서로 재현할 수 있습니다.

### 4.1 번역기 빌드 및 산출물 생성

```bash
dune build ./main.exe
./_build/default/main.exe wasm-3.0/*.spectec > output.maude 2> translate_err.txt
```

### 4.2 Maude 등식 실행 확인

```maude
load wasm-exec
rew in WASM-FIB : steps(fib-config(i32v(5))) .
```

기대 결과:

- `result ExecConf:` 출력
- 최종 명령열이 `CTORCONSTA2(CTORI32A0, 5)` 형태로 수렴

### 4.3 Maude LTL 모델체킹 확인

```maude
load wasm-exec
red in WASM-FIB-PROPS : modelCheck(mc-fib-config(i32v(5)), <> result-is(5)) .
red in WASM-FIB-PROPS : modelCheck(mc-fib-config(i32v(5)), [] ~ trap-seen) .
```

기대 결과:

- 두 질의 모두 `result Bool: true`

---

## 5. 로그/산출물 위치

자동 스크립트 실행 시 아티팩트는 다음 구조로 저장됩니다.

- `artifacts/<timestamp>/current/`
- `artifacts/<timestamp>/legacy/`
- `artifacts/<timestamp>/legacy-safe/`

주요 파일:

- `run.log`: 빌드/번역 로그
- `output.maude`: 해당 실행 모드 산출물
- `translate_err.txt`: 번역 stderr
- `maude_smoke.log`: current/legacy full smoke 로그
- `maude_sanity.log`: legacy-safe sanity 로그

참고로 스크립트는 각 모드 실행 후 루트에도 최신 `output.maude`, `translate_err.txt`를 복사합니다.

---

## 6. 성공/실패 판정 기준

`scripts/regen_and_smoketest.sh`는 아래 기준을 자동 검사합니다.

### 6.1 smoke 성공 기준 (current, legacy)

- `steps(fib-config(i32v(5)))` 질의가 로그에 존재
- `result ExecConf:` 존재
- `result Bool: true`가 최소 8개 이상
- 아래 실패 마커가 없어야 함
  - `counterexample`
  - `Fatal error`
  - `stack overflow`
  - `deadlock`

### 6.2 legacy-safe 성공 기준

- `fib-config(i32v(0))` rewrite 로그 존재
- `result ExecConf:` 존재
- `parse error`, `Fatal error`, `stack overflow` 부재

---

## 7. 기준 회귀 결과 (2026-04-17, current)

실행 명령:

```bash
./scripts/regen_and_smoketest.sh current
```

기준 로그 샘플: `artifacts/20260417_122546/current/maude_smoke.log`

| 질의 | 결과 | rewrites |
|---|---|---:|
| `steps(fib-config(i32v(5)))` | `result ExecConf` (최종 값 `i32.const 5`) | 38,096 |
| `modelCheck(mc-fib-config(i32v(5)), <> result-is(5))` | `true` | 1,002,179 |
| `modelCheck(mc-fib-config(i32v(5)), [] ~ trap-seen)` | `true` | 1,002,091 |
| `modelCheck(mc(bench-add-config), <> result-is(42))` | `true` | 84 |
| `modelCheck(mc(bench-add-config), [] ~ trap-seen)` | `true` | 83 |
| `modelCheck(mc(bench-muladd-config), <> result-is(47))` | `true` | 316 |
| `modelCheck(mc(bench-muladd-config), [] ~ trap-seen)` | `true` | 314 |
| `modelCheck(mc(bench-local-config), <> result-is(1))` | `true` | 158 |
| `modelCheck(mc(bench-local-config), [] ~ trap-seen)` | `true` | 155 |

요약:

- current 모드에서 fib + 3 benchmark의 도달성/무트랩 속성이 모두 참입니다.
- legacy full modelcheck는 deadlock counterexample 가능성이 있어 최종 결과 보고용 모드로 사용하지 않습니다.

---

## 7.1 로드 Warning/Advisory 해석

`load output`, `load wasm-exec` 시 관찰되는 대량 warning/advisory의 정량 통계, 패턴 taxonomy, 원인-해결 매트릭스는 별도 문서로 관리합니다.

- `docs/maude_warning_analysis.md`

---

## 8. 권장 보고 정책

- 논문/발표 표에는 `current` 결과만 사용
- `auto`의 `legacy-safe` 폴백은 번역 지속성 확보용으로만 사용
- `legacy`는 비교/디버깅 참고자료로만 사용

---

## 9. 제출 전 체크리스트

1. `./scripts/regen_and_smoketest.sh current` 성공 여부
2. `result Bool: true` 최소 8개 확인
3. `counterexample`, `deadlock`, `stack overflow` 부재 확인
4. 최신 `output.maude`, `translate_err.txt` 생성 확인
5. README의 문서 링크가 현재 docs 구조와 일치하는지 확인
