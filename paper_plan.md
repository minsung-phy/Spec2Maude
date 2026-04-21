# Spec2Maude — 논문 제출 계획 (paper_plan.md)

작성일: 2026-04-20
기준: 현재 STATUS.md (fib(0)~fib(5) rewrite/modelCheck 통과, 단 manual override 9종 · 미번역 22개 rule · benchmark fib 단독).

---

## 0. 목표 재확인

- **1순위 (realistic target)**: 2027년 하반기 submission, **우수티어** — VMCAI 2028 / TACAS 2028 / ESOP 2028 / FM 2027.
- **Stretch goal**: CAV 2028 (submission 2028-01).
- **Dream goal**: PLDI 2028 / POPL 2028 / OOPSLA 2028 — **조건부 가능**. Wasm 3.0 spec 관련 research win (예: 새 feature 의 모호성/버그 발견) 이 있어야 함.

확률 재기입:
- 우수티어 accept: 70~80%
- CAV 2028: 35~45%
- PLDI/POPL 2028: 15~25%

(Note: 이전 버전은 "spec 버그 발견" 에만 의존한 가정으로 최고티어 확률을 더 낮게 잡았음.
C3 를 broader 하게 재정의(§1)하면서 업데이트함.)

---

## 1. 연구 기여 (Paper Contribution) 후보 3개 — 1개는 반드시 확보

논문이 reviewer 의 "so what?" 질문에 답할 수 있으려면, 아래 중 **최소 1개** 는 확보해야 함.
티어 목표에 따라 필요 개수가 다름.

### C1. SpecTec IL 전체 자동 번역 (baseline 기여)
- 내용: SpecTec → Maude 변환을 IL level 에서 일반 로직으로 수행. 기존 K-Wasm, Ott-Wasm 은 hand-curated.
- 강점: 유일함. Wasm 3.0 전체 (GC, exception, SIMD 등) 를 가장 먼저 공식 spec 으로부터 자동 생성.
- 약점: "그래서 왜 중요한데?" 에 대한 추가 이야기 필요. 단독으로는 우수티어도 아슬아슬.
- 현재 진행도: ~60%. translator 는 동작하지만 22개 rule 미번역 + manual override 9종.

### C2. Maude-based LTL Model Checking 활용 (mechanism 기여)
- 내용: Maude 의 내장 LTL model checker 를 활용, Wasm 프로그램의 safety/liveness property 검증.
- 강점: K framework 대비 명확한 기술적 차별점 (K 는 LTL 내장 아님, 외부 도구 필요).
- 실험 계획:
  - fib 같은 loop-based program 의 termination (liveness) 검증
  - trap-free-ness, type-preservation 같은 invariant 검증
  - K-Wasm 과 동일 프로그램 비교 벤치마크
- 현재 진행도: fib 단일 프로그램에서만 `<> result-is(N)`, `[] ~ trap-seen` 검증 성공.

### C3. Unique Findings via Maude Model Checking (research win, top-tier 접근 경로)

이 프로젝트의 고유 강점인 **LTL model checking 내장** 을 활용해 기존 도구로는 못 찾는 것을
찾아내는 contribution. 아래 (a)~(d) 중 **최소 2개** 확보 목표.

#### (a) Spec 모호성 / 미정의 동작 발견 (★★★★★)
- Wasm 3.0 draft spec 의 모호성 또는 미정의 케이스를 실제 발견, bug report.
- 타겟 영역:
  - GC proposal — struct/array allocation semantics, ref cast semantics, null handling
  - Exception proposal — try_table scope, nested handler, rethrow interaction
  - Relaxed SIMD — non-deterministic operation specification
  - Memory64 / multi-memory interaction
- 강점: 있으면 PLDI/POPL 거의 확정권.
- 리스크: 운이 크게 작용, 없을 수도 있음.

#### (b) Production engine 과의 Differential Testing (★★★★)
- 내 Maude semantics ↔ V8, SpiderMonkey, wasmtime, reference interpreter 실행 결과 비교.
- 차이 발견 시 (b-1) engine 버그 또는 (b-2) spec 모호성 → 둘 다 논문 기여.
- 강점: 체계적으로 얻을 수 있음. Wasm 계열 PLDI/CAV 논문에서 자주 쓰이는 주류 접근.
- 필요 엔지니어링: 공통 input format + output normalizer + automatic minimizer.

#### (c) LTL Property 의 최초 체계적 검증 (★★★★) — **가장 확정적 경로**
- Wasm 3.0 새 feature 에 대한 liveness / progress / fairness property 를 model checker 로 검증.
- K-Wasm / Ott / Lem / reference interpreter 로는 불가능한 영역.
- 예시 property:
  - `[] (running → <> terminated)` — loop termination under all schedules
  - `[] (has-ref(r) → <> cleared(r))` — reference eventually cleaned
  - `[] ~ stuck` — progress, "stuck state 없음"
  - `[] (throw → <> handler-matched)` — exception always caught
- 강점: 운이 아닌 **엔지니어링만으로 확정적으로 얻을 수 있음**. 이 프로젝트의 기술적 USP.
- 리스크: "이 property 가 논문적 의미가 있는가?" 를 Related Work 로 정당화해야 함.

#### (d) Wasm 3.0 새 Feature 의 Edge Case Enumeration (★★★)
- GC, exception, relaxed SIMD 같은 새 feature 의 corner case 를 model checker 로 체계적 enumerate.
- 예: "struct.get 의 null ref → trap", "exception rethrow 의 stack preservation" 같은 micro-spec 하나하나를 formal 하게 확인.
- 강점: 논문의 evaluation 섹션을 탄탄하게 만듦. "최초의 체계적 분석" 이라는 framing 가능.
- 리스크: 단독으로는 PLDI bar 에 못 미침. (a)/(b)/(c) 와 조합해야 강해짐.

#### 현재 진행도
- (a): 0%. 아직 시도 안 함.
- (b): 0%. Differential harness 엔지니어링 필요.
- (c): ~10%. fib 에서 `<> result-is(N)`, `[] ~ trap-seen` 은 돌려봄. 일반화 안 함.
- (d): 0%. benchmark 확장 후 가능.

### 티어별 필요 조건

| 티어 | 필요 기여 |
|------|----------|
| VMCAI/TACAS/FM/ESOP | C1 + C2 |
| CAV / OOPSLA | C1 + C2 + C3(c) 또는 C3(d) |
| PLDI / POPL | C1 + C2 + C3 중 **2개 이상** (최소 (c) + (b) 또는 (c) + (a) 조합) |

**핵심 인사이트**: C3(c) 만 확실히 확보해도 **CAV 현실권**. 여기에 (b) 나 (a) 하나 붙으면 **PLDI/POPL 접근권**.
즉 "spec 버그 발견" 이 유일한 최고티어 경로가 아님 — (c) + (b) 조합도 유효.

---

## 2. 6단계 로드맵 (2026-04 ~ 2027-10)

### Phase 1: Correct-First Transliteration (= 0421 Step 0 + Step 1, 2026-04 ~ 2026-06, 2개월)

**목표 (0421 미팅 반영)**: C1 coverage 를 "쉽고 느린 conditional 변환"으로 **먼저 correct 하게** 확보 +
우선 `-- Step:` rule 카탈로그 완성.

작업 — Step 0 (2026-04 ~ 2026-05, 4주):
- [ ] baseline 전용 변환기 `translator_bs.ml` 분리
- [ ] 모든 Step 계열 rule (`Step`/`Step-pure`/`Step-read` + condition 있는 relation rule) 을 **`crl` + `step` 래퍼 + conditional** 단순형으로 1:1 변환
  - 형태: `crl [step-r] : step(X) => Y' if … /\ step(Y) => Y' .`
- [ ] `wasm-exec.maude` **9개 manual override 전부 제거**. Translator 자동 생성만으로 fib 이 (느려도) 통과해야 함.
- [ ] fib 외에 Wasm 3.0 전체 (core + concurrency) 가 이 단순형으로 rewrite 가능한지 확인
- [ ] 단순형 산출물을 **differential testing baseline** 으로 저장 (Phase 3 에서 재사용)
- [ ] Static semantics 중 dynamic rule 이 참조하는 부분은 **`eq/ceq`** 로 변환 (mb/cmb 불필요)

작업 — Step 1 (2026-05 ~ 2026-06, 4주):
- [ ] SpecTec 전체 (미래 섹션 포함) **`-- Step:`이 붙은 rule** 전수 수집
- [ ] 패턴별 분류표: LHS shape / ctxt 여부 / RHS 함수 호출 여부 / IterPr·IterE 여부
- [ ] "22개 미번역" 숫자 재검증 + 현재 진짜 남은 범주 분류
- [ ] 필요하면 다음 단계에서 범위를 `-- if` 일반 rule까지 확장

**완료 기준**:
- `wasm-exec.maude` manual override 0건
- translator 변환 rule 수 / 전체 rule 수 표 재현 가능
- condition 패턴 카탈로그 문서 1개

**주의 (0421 미팅)**: 이 단계에서 "빠르게 돌아가면" 오히려 의심할 것. correct 여부가 먼저.

### Phase 2: Generalization & Instrs Context (= 0421 Step 2 + Step 3, 2026-06 ~ 2026-08, 2개월)

**목표**: Phase 1 의 느린 conditional 변환을 **의미 보존하면서 최적화**.
특히 `instrs` evaluation context 의 heat/cool 일반 이론 확립.

작업 — Step 2 (2026-06 ~ 2026-07):
- [ ] Value subsort 세분화: `WasmTerminals` 아래 `Val` / `NonValInstr` subsort 를 SpecTec 정의 기반으로 강화
  - VSTACK/IQUEUE 전역 리팩터는 **forward-compat 리스크** 로 보류 (0421 미팅)
- [ ] Nondeterministic instrs heating + side condition 으로 "의미 있는 fragment 하나" 만 pick
- [ ] label/handler/frame heat/cool 은 유지, 동일 방법론으로 문서화
- [ ] Phase 1 baseline 과 differential 실행 — 결과 다르면 heat/cool 잘못된 것

작업 — Step 3 (2026-07 ~ 2026-08):
- [ ] Translator 가 "조건 만족 rule 은 correct 변환, **조건 불만족 rule 은 reject**" 하도록 완성
- [ ] 조용한 오변환 0 건을 보장하는 자가 검증 로직

**완료 기준**:
- translator 로 변환된 rule 전부 Phase 1 baseline 과 실행 결과 일치
- 불만족 rule 에 대해 명시적 reject 메시지
- `multiple distinct parses` 37건 / `assignment condition already bound` 8건 해소

### Phase 2.5: Benchmark Suite (2026-08 ~ 2026-09, 1개월)

**목표**: fib 외 4~7개 benchmark 추가, 수치 측정.

benchmark 후보 (난이도 순):
- [ ] factorial (recursion)
- [ ] mutual recursion (is_even / is_odd)
- [ ] iterative sum / product
- [ ] memory operations (i32.load / i32.store)
- [ ] table operations (indirect call)
- [ ] GC proposal simple example (struct alloc/get)
- [ ] exception proposal simple example (try/catch/throw)

**완료 기준**:
- 각 benchmark 의 rewrite 시간, modelCheck 시간 테이블
- K-Wasm 비교 1~2개 이상 (같은 프로그램 같은 property)

### Phase 3: Research Contribution Attempt (2026-09 ~ 2026-12, 4개월)

**목표**: C2 기술적 기여 확정 + C3 (a)~(d) 중 최소 2개 확보.

우선순위는 **"확정적으로 얻을 수 있는 것" → "운이 필요한 것"** 순서.
즉 **C3(c) → C3(d) → C3(b) → C3(a)** 순으로 투자.

#### C2 (Model Checking 활용, 기본 기여)
- [ ] 각 benchmark 에 대한 LTL property 3가지 이상 검증
  - `<> result-is(N)` (reachability)
  - `[] ~ trap-seen` (safety)
  - `[] ~ stuck` (progress)
- [ ] K-Wasm 과 같은 property 검증 가능 여부 비교 (K 는 외부 도구 필요)
- [ ] 검증 시간 / 상태공간 크기 측정

#### C3(c) LTL Property 의 최초 체계적 검증 — **필수, 2개월 안에 확정**
- 2026-08 ~ 2026-09
- [ ] Wasm 3.0 새 feature 별 "의미 있는 LTL property" 카탈로그 작성
  - GC: reference lifecycle properties
  - Exception: handler matching invariants
  - Control: branch/return progress
- [ ] 각 property 를 최소 2개 benchmark 에서 검증
- [ ] "이 property 는 기존 도구로는 불가능" 을 Related Work 에 명시
- **Exit criterion**: 10개 이상의 property 검증 결과 테이블 확보

#### C3(d) Edge Case Enumeration — **병행 진행**
- 2026-09 ~ 2026-10
- [ ] Wasm 3.0 새 feature 의 corner case 를 체계적으로 리스트화
  - 각 corner case 를 작은 test program 으로 캡슐화
  - Model checker 로 possible outcomes 열거
- [ ] reference interpreter 결과와 교차 확인
- **Exit criterion**: corner case 20개 이상, 각각 formal 하게 specified outcomes 기록

#### C3(b) Differential Testing — **2개월 도전, 안 되면 포기**
- 2026-10 ~ 2026-11
- [ ] Differential harness 엔지니어링
  - Common input: `.wasm` binary
  - Runners: Maude semantics, reference interpreter, wasmtime, V8 (d8)
  - Output normalizer (trap message, value, store state)
  - Automatic test generator (basic random fuzzer)
- [ ] 차이 발견 시 자동 minimize
- **Exit criterion 낮음 허들**: harness 동작 + 최소 1개 차이 발견
- **Exit criterion 높음 허들**: 차이 3개 이상 + 원인 분석 완료
- 안 되면: Phase 3 끝에서 포기, C3(c)+C3(d) 로 우수티어 확정

#### C3(a) Spec Ambiguity Discovery — **기회주의적 접근**
- 2026-11 ~ 2026-12
- C3(c)/(d)/(b) 작업 중 **자연스럽게** 모호성이 발견되면 즉시 기록
- 체계적 탐색 시도:
  - [ ] Wasm spec github issues 검토, open 된 ambiguity 후보 list 화
  - [ ] 각 후보를 model checker 로 재현 시도
  - [ ] 발견된 모호성은 WebAssembly/spec repo 에 issue 로 report
- **이게 나오면 jackpot**: PLDI/POPL 거의 확정권
- **안 나와도 괜찮음**: C3(c)+(d) 또는 C3(c)+(b) 로 우수티어/CAV 확보 가능

### Phase 3 판정 게이트 (2026-12 말)

연구 방향을 확정하는 **goto 포인트**:

| 확보 상태 | 최종 target |
|----------|-------------|
| C3(c) + (d) 만 확보 | VMCAI/TACAS 2028 (우수티어 확정) |
| C3(c) + (d) + (b) | CAV 2028 도전 + VMCAI b-plan |
| C3(c) + (b) + (a) 1개라도 | PLDI/POPL 2028 도전 + CAV b-plan |
| C3(c) 조차 미완료 | 계획 재검토 필수 |

### Phase 4: Semantic Preservation Argument (2026-12 ~ 2027-02, 2개월)

**목표**: reviewer 가 "의미 보존이 증명되었나?" 라고 물을 때 답할 준비.

작업:
- [ ] Key lemma 정식 기술
  - Lemma: SpecTec `z → z'` 는 Maude `step(< z | i >) → < z' | i' >` 와 bisimilar
  - Lemma: Heating/Cooling 은 observable behavior 에 영향 없음 (context rule 의 의미 보존)
  - Lemma: `rl/crl` 사용이 `eq/ceq` 대비 왜 필수인지 (Coherence / frozen 설명)
- [ ] Proof sketch 작성 (mechanization 안 해도 됨, 우수티어는 informal 로 OK)
- [ ] Counterexample 검토: "만약 `eq/ceq` 로 번역했으면 어떤 프로그램에서 의미가 깨지는가" 를 예시로 제시

**완료 기준**:
- Paper 의 "Correctness" 섹션 초안 완성

### Phase 5: First Paper Submission (2027-02 ~ 2027-05)

**목표**: b-plan 으로 우수티어 1차 제출 (reject 되어도 feedback 용).

타겟:
- [ ] **FM 2027** (submission 2027-05, ~13개월 시점)
- 또는 **CAV 2027** (submission 2027-02, 가능하면 스트레치)

submission 준비:
- [ ] 논문 초안 (13~15 페이지 LNCS format)
- [ ] Artifact (Docker image, reproducible script)
- [ ] Supplementary: benchmark result table

목적:
- 실제 reviewer feedback 얻기
- 설령 reject 되어도 2차 submission 준비에 큰 도움
- accept 되면 게임 끝

### Phase 6: Main Submission (2027-05 ~ 2027-10)

**목표**: Phase 5 feedback 반영, main submission.

시나리오별 전략:

**시나리오 A: C3(c) + (b) + (a) 모두 확보 (운 좋은 case)**
- Target: **PLDI 2028** (submission 2027-11) 또는 **POPL 2028** (submission 2027-07)
- 논문 방향: "We translate Wasm 3.0 SpecTec to Maude, enabling LTL model checking, and find N spec ambiguities and M engine discrepancies via differential testing."
- B-plan: 같은 원고로 CAV 2028 또는 OOPSLA 2028 에 즉시 재제출

**시나리오 B: C3(c) + (b) 또는 C3(c) + (d) 확보 (현실적 main case)**
- Target: **CAV 2028** (submission 2028-01) 또는 **OOPSLA 2028 R2** (submission 2027-10)
- 논문 방향: "LTL model checking of Wasm 3.0 programs via automatic translation from SpecTec, covering liveness/progress properties inaccessible to prior frameworks."
- B-plan: VMCAI 2028 / TACAS 2028 재제출

**시나리오 C: C3(c) 만 확보 (b-plan case)**
- Target: **VMCAI 2028** (submission 2027-09~10), **TACAS 2028** (submission 2027-10)
- 논문 방향: "Mechanized semantics of Wasm 3.0 via automatic translation, with built-in LTL model checking."
- B-plan: ESOP 2028 / FM 2028 재제출

---

## 3. Risk Register

| 리스크 | 확률 | 영향 | 완화책 |
|--------|------|------|--------|
| Engineering 단계에서 fib 외 benchmark 가 자꾸 새 bug 유발 | 중 | 상 | Phase 1 을 여유있게, debug 시간 budget 미리 책정 |
| C3(a) (spec 모호성) 안 나옴 | 고 | 저 | 애초부터 (a) 는 bonus. (c)+(d) 또는 (c)+(b) 로 우수티어/CAV 확보 가능 |
| C3(b) (differential testing) harness 완성 못 함 | 중 | 중 | 2개월 타임박스. 안 되면 깔끔히 포기, (c)+(d) 로 수렴 |
| C3(c) (LTL property) 가 "의미 없다" 공격 받음 | 중 | 상 | Related Work 에서 "다른 도구로 못 함" 을 명시, property 선정 근거를 prose 로 강화 |
| K-Wasm 비교 에서 현저히 느리게 나옴 | 중 | 상 | Phase 3 초반에 성능 측정, 필요시 Maude 최적화 (frozen, memo) |
| 리뷰어가 "Ott/Lem 에 비해 새로운 게 뭐냐" 공격 | 고 | 상 | Related work 섹션을 초기부터 강화, Ott/Lem/K 와의 차이 명시 |
| 번역기가 SpecTec 이외의 spec 에 적용 안 됨 → generality 주장 약함 | 중 | 중 | SpecTec 로 쓰인 다른 small spec (예: MiniML) 을 1개라도 실험 |
| 논문 작성 늦어져 submission 놓침 | 중 | 상 | Phase 5 의 "pilot submission" 이 강제 deadline 역할 |
| 혼자 진행 시 물리적 시간 부족 | 고 | 상 | 교수님 / 랩 메이트 와 co-author 협의, benchmark / writing 분담 |

---

## 4. Weekly / Monthly Milestones

### 2026년 남은 기간

| 월 | 주요 milestone |
|----|----------------|
| 2026-04 ~ 05 | **Step 0**: 모든 Step rule 을 conditional `crl` 로 단순 변환, manual override 9종 제거, fib+전체 Wasm 통과 확인 |
| 2026-05 ~ 06 | **Step 1**: SpecTec 전체 rule condition 카탈로그 + "22개" 재검증 |
| 2026-06 ~ 07 | **Step 2**: Val/NonValInstr subsort 강화, instrs heat/cool 일반화, differential 확인 |
| 2026-07 ~ 08 | **Step 3**: translator reject 로직 완성, parse warning 정리 |
| 2026-08 ~ 09 | benchmark (factorial, sum, mutual recursion, memory/table) + K-Wasm 비교 |
| 2026-09 | C3(c) LTL property catalog 작성, benchmark 별 검증 |
| 2026-10 | C3(d) edge case enumeration + C3(b) differential harness 시작 |
| 2026-11 | C3(b) 판정 (성공/포기), C3(a) 기회주의적 탐색 |
| 2026-12 | Phase 3 판정 게이트: 확보된 C3 조합으로 target 티어 결정 |

### 2027년

| 월 | 주요 milestone |
|----|----------------|
| 2027-01 | Proof sketch 완성, artifact 엔지니어링 |
| 2027-02 | 논문 초안 완성 (CAV 2027 stretch submission 여부 결정) |
| 2027-03 | Feedback 반영, revision |
| 2027-04 | OOPSLA 2028 R1 submission (optional) |
| 2027-05 | FM 2027 submission (b-plan) |
| 2027-06 | 결과 대기 동안 benchmark 확대 |
| 2027-07 | POPL 2028 submission 여부 결정 (C3 있으면) |
| 2027-08 | 논문 revision 집중 |
| 2027-09 | VMCAI 2028 submission (fallback) |
| 2027-10 | TACAS 2028 / ESOP 2028 submission |
| 2027-11 | PLDI 2028 submission 여부 최종 결정 (C3 있으면) |

---

## 5. 즉시 실행 액션 (다음 2주)

이 계획이 실제로 동작하려면 지금 당장 해야 하는 것들.

1. [ ] **논문 스토리 1줄 쓰기** (이게 가장 중요)
   - 예: *"We present Spec2Maude, the first automatic translator from the WebAssembly 3.0 SpecTec IL to Maude's rewriting logic, enabling LTL model checking of Wasm programs."*
   - 이 한 줄이 모든 의사결정의 기준이 됨
   - 교수님께 공유, 피드백 받기

2. [ ] **fib nested label deadlock 완전 종결**
   - Phase 1 이 여기서부터 시작. 이게 안 풀리면 전체 일정 밀림.
   - 2026-04-30 까지 데드라인 설정 권장

3. [ ] **Related work 서베이 시작**
   - K-Wasm, Ott, Lem, PLT Redex, 각각 "what they do / what we differ" 1문단씩
   - 약점 (generality, LTL, automation) 을 3개 이상 찾아두기

4. [ ] **SpecTec rule 카운트 측정**
   - 전체 rule 수, 자동 번역 성공 수, 실패 수 를 스크립트로 출력
   - 현재 "22개 미번역" 이라는 숫자가 정확한지 재확인

5. [ ] **2주 후 체크포인트**
   - 위 4개 완료 여부 / 진행률 점검
   - 안 되면 계획 수정

---

## 6. 논문 structure draft (최종 submission 기준)

```
1. Introduction
   - Motivation: Wasm 3.0 spec 의 공식 formalism 필요성
   - SpecTec 의 등장과 그 실행 가능성 부재
   - Contribution: 자동 번역 + LTL model checking
2. Background
   - WebAssembly 3.0 & SpecTec
   - Maude rewriting logic & model checking
3. Translation Rules
   - Pattern 1: General RelD → mb/cmb
   - Pattern 2: Step-pure → crl step(...)
   - Pattern 3: Step-read → crl with state read
   - Pattern 4: Step → crl with state transition
   - Evaluation context: heating/cooling
4. Correctness (Semantic Preservation)
   - Key lemmas
   - Proof sketch
5. Implementation
   - OCaml translator (translator.ml) 아키텍처
   - output.maude 의 예시 생성물
6. Evaluation
   - Benchmark suite (fib, factorial, memory, GC, exception)
   - LTL property 검증 결과
   - K-Wasm 과의 비교 (성능, 표현력)
   - [if C3] Wasm 3.0 spec 에서 발견된 모호성 사례
7. Related Work
   - K-Wasm, Ott-Wasm, Lem, PLT Redex
8. Conclusion & Future Work
```

---

## 7. 요약

- **현실적 1순위 목표**: VMCAI 2028 / TACAS 2028 / ESOP 2028 (2027-09~10 submission). C3(c) 하나만 확실히 확보하면 70~80% 확률.
- **Stretch goal**: CAV 2028 (2028-01 submission). C3(c) + (b) 또는 (c) + (d) 확보시 35~45% 확률.
- **Dream goal**: PLDI 2028 / POPL 2028. C3 중 2개 이상 (특히 (a) 또는 (b) 포함) 확보시 15~25% 확률.
- **핵심 변화**: "spec 버그 발견" 이 유일한 최고티어 경로가 아님. LTL property 최초 체계적 검증 (C3(c)) + differential testing (C3(b)) 조합만으로도 PLDI 접근 가능.
- **가장 큰 리스크**: engineering 구덩이에 계속 빠져 research contribution 시간이 잠식됨.
- **가장 중요한 액션 (이번 주)**: 논문 스토리 1줄 확정 + fib deadlock 종결.

---

## 8. 참고 문서

- [CLAUDE.md](CLAUDE.md) — 연구 목표 / 교수님 원칙
- [STATUS.md](STATUS.md) — 현재 구현 상태, 미해결 이슈
- [docs/logic/project_goals_and_prof_requirements.md](docs/logic/project_goals_and_prof_requirements.md) — 원본 요구사항
- [labmeeting.md](labmeeting.md) — 번역 패턴 4종 설명
- [personal_meeting_0421/evaluation_context.md](personal_meeting_0421/evaluation_context.md) — evaluation context 현황
