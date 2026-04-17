# 실험 재현 절차 

> 작성일: 2026-04-17

## 1. 목적

이 문서는 아래를 재현하기 위한 최소 절차를 제공합니다.

- 번역기 재생성 (`output.maude`)
- WebAssembly 실행 스모크 (`steps`)
- LTL 모델체킹 (fib + non-fib 3개)
- current 실패 시 legacy-safe 폴백

## 2. 사전 요구사항

- macOS + Maude 3.5.1
- `dune`/OCaml 빌드 환경
- 프로젝트 루트에서 실행

선택 환경변수:

```bash
export MAUDE_BIN=/Users/minsung/Dev/tools/Maude-3.5.1-macos-x86_64/maude
```

## 3. 실행 커맨드

### 3-1. 권장 (연구 결과용)

```bash
./scripts/regen_and_smoketest.sh current
```

### 3-2. 자동 폴백

```bash
./scripts/regen_and_smoketest.sh auto
```

동작 순서:

1. `current` 실행
2. 실패 시 `legacy-safe` 실행
3. `legacy-safe`는 번역 + load sanity만 검증

### 3-3. 비교/디버그용

```bash
./scripts/regen_and_smoketest.sh legacy
```

주의: 현재 기준 `legacy` full modelcheck는 deadlock counterexample이 있어 연구 결과 보고에 부적합.

## 4. 로그 산출 위치

실행마다 아래 경로 생성:

- `artifacts/<timestamp>/current/`
- `artifacts/<timestamp>/legacy/`
- `artifacts/<timestamp>/legacy-safe/`

주요 파일:

- `run.log`: 빌드/번역 로그
- `output.maude`: 해당 모드 생성 산출물
- `translate_err.txt`: 번역 stderr
- `maude_smoke.log`: full 모델체킹 로그
- `maude_sanity.log`: legacy-safe sanity 로그

## 5. 기준 실행 결과 (샘플)

- current 성공 로그: `artifacts/20260417_122546/current/maude_smoke.log`
- legacy-safe 성공 로그: `artifacts/20260417_122531/legacy-safe/maude_sanity.log`
- legacy 실패 로그: `artifacts/20260417_122429/legacy/maude_smoke.log`

요약:

- current: fib + 3 benchmark의 `result-is`/`~trap` 모델체킹 전부 `result Bool: true`
- legacy-safe: 로딩/기본 rewrite sanity는 통과
- legacy: `counterexample(... deadlock)` 발생 (full 보증 실패)

## 6. 벤치 구성

`wasm-exec.maude` 내 실행 구성:

- `fib-config(i32v(N))`
- `bench-add-config` -> 기대 결과 42
- `bench-muladd-config` -> 기대 결과 47
- `bench-local-config` -> 기대 결과 1
