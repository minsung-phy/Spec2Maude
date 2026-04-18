# CLAUDE.md — Spec2Maude 프로젝트 가이드 (AI Assistant 용)

이 문서는 Claude/다른 AI 어시스턴트가 이 저장소에서 작업할 때 **먼저 읽어야 하는 맥락 문서**다.
절대 지켜야 할 교수님 요구사항, 프로젝트 구조, 현재 상태를 한 곳에 모았다.

---

## 0. 한 줄 요약

WebAssembly 3.0의 공식 명세 언어 **SpecTec** 을 Rewriting-Logic 시스템 **Maude** 로 **자동 변환**하고, 그 결과 위에서 **실행 및 모델체킹**을 수행하는 연구용 컴파일러.

---

## 1. 연구 목표 (큰 그림)

원본: [docs/logic/project_goals_and_prof_requirements.md](docs/logic/project_goals_and_prof_requirements.md)

- SpecTec 명세를 재활용 가능한 형태로 분석/검증하는 **연구 파이프라인**을 만드는 것이 목표다.
- 단순 실행기 제작이 아니다. "SpecTec 계열 언어 전반"으로 확장 가능한 변환기가 궁극 목표.
- 최종 산출물은 **논문 (PLDI 지향)**.
- 사례 연구: fib 같은 작은 Wasm 프로그램의 속성 검증 → 의미론적 문제 발견 가능성.

### 입출력
- **입력**: SpecTec EL → 정제된 **IL AST** ([wasm-3.0/](wasm-3.0/) 의 `.spectec` 파일들)
- **출력**: 실행/검증 가능한 **Maude 모듈** ([output.maude](output.maude))
- **핵심**: 하드코딩된 개별 규칙 나열이 아니라 **패턴 기반의 일반 변환 로직**

---

## 2. 교수님 요구사항 (절대 원칙)

출처: [meeting/0324 개인.txt](meeting/0324%20개인.txt), [meeting/0331 개인.txt](meeting/0331%20개인.txt), [meeting/meeting_log.txt](meeting/meeting_log.txt)

### 2.1 의미론 보존이 최우선
- "모양이 비슷한 것"이 아니라 **"실행 의미가 같은 것"** 을 보장해야 한다.
- SpecTec은 Top-most / Context 기반 1-step 의미인데, Maude는 임의 서브텀 위치에서 0-or-more rewrite가 가능 → 그대로 옮기면 의미가 깨진다.

### 2.2 Eq/Ceq와 Rl/Crl 혼용 리스크 관리 — **Step 규칙은 반드시 rl/crl**
- 상태 전이 영역에서 eq/ceq와 rl/crl을 무분별하게 섞는 것은 **coherence/confluence 리스크**가 크다.
- **결정 (0331 미팅)**: SpecTec 의 `Step` / `Step-pure` / `Step-read` 룰은 **반드시 `rl` / `crl` (rewriting rule)** 로 번역해야 한다. `eq` / `ceq` 는 **틀렸다**.
- 교수님 원문:
  > "스펙텍과 리라이팅 로직의 룰의 모양이 비슷해 보이지만 시멘틱스가 완전히 다르다.
  > 스텝 펑션을 프로즌으로 정리하면 ... 스텝이 무조건 붙어야만 리라이팅 룰 트랜지션이 일어나니까.
  > 이 스펙텍 룰을 그냥 eq 로 바꾸는 거랑 틀렸다."
  > ([meeting/0331 개인.txt](meeting/0331%20개인.txt) 24:03, 24:55, 27:04)
- 의도된 형태:
  ```maude
  crl [step-…] :
    step(< Z | LHS-instrs >) => step(< Z' | RHS-instrs >)
    if …conditions… .
  ```
  step 래퍼로 임의 서브텀 포지션 매칭을 차단 (프로즌 대체).
- 룰 LHS에는 reducible function symbol이 아닌 **constructor 중심 패턴**을 유지해야 안전.
- **syntax (hasType/WellTyped)** / **def** / **일반 RelD 판정 (: ValidJudgement)** 은 eq/mb/cmb 로 내리는 것이 맞다 — 이건 상태 전이가 아니므로.
- ⚠ **현재 `translator.ml` 은 이 원칙을 위반 중**. Step/Step-pure/Step-read 를 모두 `eq`/`ceq` 로 내리고 있어 재설계 필요. 자세한 상황은 [STATUS.md](STATUS.md) § P0-0 참조.
- 통합 원칙: translator.ml을 기준 변환기로 유지하고, translator_0417.ml은 통째 병합하지 않는다. 교수님 요구사항 충족에 직접 필요한 로직만 선택 통합한다. 선택 통합 범위는 Step, Step-pure, Step-read의 rl/crl 생성 경로와 Evaluation Context heating/cooling 생성 경로로 제한한다. RelD Bool 반환 체계, type-ok 체계 전환, rollrt 특수 브리지는 기본 통합 대상에서 제외한다.

### 2.3 Context 규칙은 Heating/Cooling으로 처리
- label / frame / instrs / handler 같은 **Evaluation Context** 는 **별도 heating/cooling 규칙**으로 분해/복원.
- 컨텍스트를 단순 생략하거나 "중간 스택에서도 매칭"되게 두면 잘못된 실행 발생.
- K-framework의 핵심 아이디어를 **활용**하되 K 정의를 새로 짜는 것은 **아니다**.

### 2.4 Step 단위 강제
- SpecTec의 1-step 의미를 보존하기 위해 **`step` 연산자 기반 통제** 필요.
- "룰 하나 적용 = 정확히 한 스텝" 이라는 운영 모델 유지.

### 2.5 Conditional 룰 남용 금지
- 컨디셔널 내부 계산은 **모델체킹 추적성이 낮고 성능 저하**를 크게 유발.
- 가능한 영역은 **unconditional 화** 또는 **조건 최소화**. 정말 필요한 조건만 남긴다.
- 단, RHS 함수 실패 가능성이 있는 경우 안전 가드가 있는 `crl` 형태는 허용.

### 2.6 K-Framework "직접 적용" vs "아이디어 활용"
- 이 프로젝트는 **K 정의를 새로 짜는 과제가 아니다**.
- K 핵심 아이디어 (Decomposition, Heating/Cooling) 는 활용하되, **SpecTec → Maude 변환 목표를 벗어나지 말 것**.

### 하지 말아야 할 방향 (비목표)
- K configuration 자체를 새로 정의하는 별도 K 프로젝트로 확장
- Wasm 특정 예제만 통과시키는 과도한 **하드코딩**
- 의미 보존 검토 없이 단순 텍스트 치환식 변환
- 모델체킹에 불리한 거대 conditional chaining 의존

### 구현 원칙 (내재화)
1. **정확성 > 편의성** — 우회보다 의미 보존 우선
2. **일반 규칙 > 예외 하드코딩** — 명령어 이름 하드코딩보다 IL 구조 기반 패턴
3. **Context 분해 명시화** — heating/cooling으로 분리, 추적 가능하게
4. **검증 가능성 내장** — rewrite / modelCheck 에서 즉시 검증 가능한 형태
5. **문서와 코드 동기화** — 변환 규칙 설명과 translator 코드 경로가 1:1 대응

---

## 3. 저장소 구조

```
Spec2Maude/
├── translator.ml            ← 메인 번역기 (OCaml, ~2350 line)
├── main.ml                  ← CLI 진입점
├── lib/il/                  ← SpecTec IL AST 정의 (외부)
├── wasm-3.0/                ← 입력: SpecTec .spectec 파일들
├── output.maude             ← 자동 생성 출력 (~7200 line, 커밋됨)
├── wasm-exec.maude          ← 손수 작성 실행 harness (label/frame/handler/loop context, fib 테스트)
├── rule.maude               ← 보조 Maude 정의
├── docs/
│   ├── logic/               ← 변환 로직 설명 문서
│   │   └── project_goals_and_prof_requirements.md   ← 본 요구사항 원본
│   └── experiment/          ← 실험 기록
├── meeting/                 ← 교수님 미팅 로그 (원문, 근거 자료)
│   ├── 0324 개인.txt
│   ├── 0331 개인.txt
│   └── meeting_log.txt
├── labmeeting.md            ← 랩미팅용 4 패턴 설명 (현재 작성 중)
├── STATUS.md                ← 현재 상태 / 문제점 / 할일 (AI도 이거 먼저 볼 것)
└── README.md                ← 외부 공개용 개요
```

### 번역기 핵심 함수 (translator.ml)
- `translate_typd` — TypD (syntax 선언) 처리 — sort / hasType 기반 WellTyped
- `translate_defd` / `translate_decd` — DefD / DecD (함수 정의) → eq/ceq
- `translate_reld` / `translate_step_reld` — RelD (관계 / 규칙) → cmb / step ceq
- `type_guard` — term의 타입 조건 생성 (regex 버그 이력 있음, L812-826)

### 변환 패턴 (4개)
상세: [labmeeting.md](labmeeting.md)

1. **일반 RelD 판정** → `cmb ... : ValidJudgement`
2. **Step-pure** (instr-only) → `ceq step(< Z | VALS instr IS >) = ...`
3. **Step-read** (상태 읽기 only) → 상태 z 유지한 채 결과 구성
4. **Step** (상태 변화) → `z → z'` 가 직접 나타남

---

## 4. 현재 상태

**상세는 항상 [STATUS.md](STATUS.md) 를 먼저 읽을 것.** 여기 내용은 빠르게 바뀐다.

간단 요약 (2026-04-18 기준):
- 번역 파이프라인은 안정. output.maude 자동 생성 OK.
- `labmeeting.md` 에 4 패턴 문서화 완료.
- **실행 검증 미완료**: fib modelCheck 에서 deadlock 발생 (P0 이슈).
- P0 WIP 브랜치: `wip/p0-v128-overflow` (stack overflow 미해결 채로 저장).
- main 브랜치는 `11c341b` 상태, 깨끗하지만 fib 는 deadlock.

브랜치:
| 브랜치 | 상태 |
|--------|------|
| `main` | 기준선, fib modelCheck deadlock |
| `wip/p0-v128-overflow` | P0 작업 중, V128 stack overflow 미해결 |

---

## 5. AI 어시스턴트 작업 규칙

### 반드시 할 것
- 어떤 변환 로직을 추가/수정할 때 **"교수님 요구사항 §2 중 어느 항목과 부합하는가"** 를 명시할 것.
- `translator.ml` 수정 시 **IL 구조 기반 일반 로직** 을 우선. 특정 명령어 이름 `if _ = "LOCAL.SET"` 같은 하드코딩 금지.
- output.maude 수정 금지. 항상 `translator.ml` → 재생성 → 검증 루프.
- 커밋 전에 `STATUS.md` 의 "현재 문제점" 에 영향이 있는지 확인.

### 절대 하지 말 것
- output.maude 를 직접 손으로 수정하는 커밋. (항상 translator 를 고쳐서 재생성)
- 개별 Wasm instruction 에 맞춘 switch/case 를 translator 에 추가 (§2.6 위반).
- eq/ceq 와 rl/crl 을 근거 없이 혼용 (§2.2 위반).
- **SpecTec 의 Step / Step-pure / Step-read 룰을 `eq`/`ceq` 로 번역 (§2.2 직접 위반)**. 반드시 `rl`/`crl` + step 래퍼로.
- conditional 룰에 무분별한 조건 추가 (§2.5 위반).
- "일단 돌아가게 하기 위해" 의미 보존을 포기하는 우회 (§2.1, 원칙 1 위반).
- Git 커밋 시 Claude 를 공저자(Co-Authored-By)로 추가. **작성자는 항상 `minsung-phy`**.

### 검증 루프
1. `translator.ml` 수정
2. `dune build` 로 컴파일
3. `./main <spectec-files> > output.maude` 로 재생성 (정확한 명령은 `main.ml` 확인)
4. Maude 에서 `load wasm-exec.maude`
5. 확인:
   - `red step(< ... >) .` — 단일 스텝 reducible 한가
   - `rew fib-config(...)` — rewrite 진행되는가
   - `red modelCheck(..., <> result-is(N)) .` — 도달성
   - `red modelCheck(..., [] ~ trap-seen) .` — 안정성
6. 결과를 `STATUS.md` 에 반영.

### 작업 단위
- 작은 변경 (단일 패턴 수정) → 즉시 검증 → 커밋.
- 큰 변경 (새 패턴 도입) → WIP 브랜치 → 교수님 원칙 충돌 여부 점검 → 검증 → main merge.

---

## 6. 관련 문서 인덱스

| 문서 | 용도 |
|------|------|
| [STATUS.md](STATUS.md) | 현재 상태 / 문제 / 할일 (매 세션 시작 시 필독) |
| [labmeeting.md](labmeeting.md) | 변환 4 패턴 설명 (발표/공유용) |
| [docs/logic/project_goals_and_prof_requirements.md](docs/logic/project_goals_and_prof_requirements.md) | 본 문서의 원본 요구사항 |
| [meeting/meeting_log.txt](meeting/meeting_log.txt) | 미팅 타임라인 |
| [meeting/0324 개인.txt](meeting/0324%20개인.txt) | 상세 미팅 기록 1 |
| [meeting/0331 개인.txt](meeting/0331%20개인.txt) | 상세 미팅 기록 2 |
| [README.md](README.md) | 외부 공개용 프로젝트 소개 |
