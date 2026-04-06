# Formal Architecture of Spec2Maude: Compiling WebAssembly Specification to Rewriting Logic

## 1. Overview & Formal Translation Pipeline

본 번역기(Spec2Maude)는 선언적 형태의 WebAssembly 형식 명세(SpecTec IL)를 Maude의 실행 가능한 대수적 의미론(Executable Algebraic Semantics)으로 컴파일한다. 이 변환의 핵심 목표는 파서의 모호성, 조건식 내 미바인딩(Unbound variables), 그리고 타입 조건의 상태 공간 폭발을 제어하여 다음 세 가지 불변식을 공동으로 만족하는 것이다.

$$
\textsf{Parseable} \land \textsf{Executable} \land \textsf{Confluent}
$$

전체 번역 파이프라인 $\mathcal{T}$는 다음과 같은 함수 합성으로 정의된다.

$$
\mathcal{T} = \mathcal{E}_{\mathrm{OSA}} \circ \mathcal{S}_{\mathrm{bind}} \circ \mathcal{M}_{\mathrm{mono}} \circ \mathcal{P}_{\mathrm{IL}}
$$

- $\mathcal{P}_{\mathrm{IL}}$: SpecTec IL 정규화
- $\mathcal{M}_{\mathrm{mono}}$: 믹스픽스(Mixfix) 및 다형성 표기의 정규 1차 생성자화 (Monomorphization)
- $\mathcal{S}_{\mathrm{bind}}$: 전제 의존성 그래프 기반 선행 바인딩 스케줄링 (Binding Scheduling)
- $\mathcal{E}_{\mathrm{OSA}}$: Order-Sorted Algebra (OSA) 기반 타입 임베딩

이를 형식적으로 정의한 변환 함수 $\phi : \mathrm{AST}_{\mathrm{SpecTec}} \to \mathrm{Module}_{\mathrm{Maude\text{-}OSA}}$는 다음과 같이 각 IL 정의(DecD, TypD, RelD)를 구성적으로(Compositionally) Maude 코드로 매핑한다.

$$
\phi(\mathrm{TypD}(T,\vec{p},\mathcal{I})) =
\left\{\begin{array}{l}
\texttt{sort }\widehat{T}\texttt{ .}\\
\texttt{subsort }\widehat{T}\texttt{ < WasmType .}\\
\texttt{mb/cmb } t : \widehat{T}\texttt{ .}
\end{array}\right.
$$
$$
\phi(\mathrm{DecD}(f,\vec{p},\tau,\mathcal{C})) =
\left\{\texttt{op }\widehat{f} : \sigma_1\ \dots\ \sigma_n \to \sigma_r\texttt{ .},\;\texttt{eq/ceq}\right\}
$$

---

## 2. Monomorphization of Mixfix Syntax

### Problem
Wasm 원본 명세는 믹스픽스(Mixfix) 표기와 다형적 서명을 폭넓게 사용한다. 이를 단순 텍스트 매핑으로 Maude에 투입하면 동일 토큰열에 대한 다중 파스 트리(`multiple distinct parses`)가 발생하며, 조건식 내부의 정렬(Sort) 판정이 지연되는 치명적인 파서 비결정성이 유발된다.

### Technique
번역기는 $\mathcal{M}_{\mathrm{mono}}$ 단계를 통해 모든 핵심 생성자를 Arity가 태깅된 정규 접두 생성자(Canonical First-order Constructor) $\mathsf{CTOR\_F\_A}k$로 강제 직렬화한다.

$$
\llbracket f\;t_1\;\dots\;t_k \rrbracket \mapsto \mathsf{CTOR\_F\_A}k(\llbracket t_1 \rrbracket,\dots,\llbracket t_k \rrbracket)
$$

### Effect
- **파싱 유일성 확보:** $\forall t,\;\#\mathrm{parse}(t)=1$
- 믹스픽스 해석 의존성을 완전히 제거하고, 후속 바인딩/정렬 변환의 입력을 1차 항(First-order term)으로 정규화한다.

---

## 3. Algebraic Type Embedding (OSA & MEL)

### Problem
기존 연구들처럼 복잡한 종속 타입(Dependent type)과 리스트 타입을 불리언 조건부 동치식(예: `type-ok(...) = true`)으로 처리하면 조건의 길이가 급증하고 분기 폭(Branching factor)이 폭발한다.

### Technique
Spec2Maude는 타입 판정을 불리언 계산이 아닌 Maude의 네이티브 OSA 멤버십 공리(`mb`, `cmb`)로 승격시킨다.

$$
\mathrm{TypeCheck}(t,\tau) \rightsquigarrow (t : \tau)\;\text{or}\;\mathrm{mb}\;t : \tau
$$

생성자 타입의 형식 규칙(TypD-Variant)은 다음과 같이 멤버십 등식 논리(Membership Equational Logic, MEL)로 직역된다.

$$
\frac{\forall i.\ \Gamma \vdash a_i : A_i \quad \Gamma \vdash \Pi}
     {\Gamma \vdash K(\vec{a}) : T}
\Rightarrow
\texttt{cmb }K(\vec{a}) : T\texttt{ if }\Gamma(\vec{a}) /\\\ \Pi=\texttt{true}\texttt{ .}
$$

### Monoidal Instruction Semantics
또한, 명령어의 리스트 타입(`WasmTerminals`) 연산에서 발생하는 조합 폭발을 막기 위해, 리스트를 빈 값(`eps`)을 항등원으로 갖는 모노이드(Monoid)로 모델링한다.
$$(\mathrm{WasmTerminals},\;\_\_\;,\;\mathrm{eps})$$
이는 `assoc` 속성을 통해 재작성 매칭(Rewrite matching) 시 괄호 결합합 법칙의 민감도를 제거하고 시퀀스 생성 규칙을 단순화한다.

---

## 4. Intelligent Binding Scheduling for Confluence

### Problem
SpecTec 전제식(Premises)은 선언적이므로 실행 순서(Control flow)를 내장하지 않는다. 변수의 사용이 변수 도입보다 선행하거나, 매칭 제약과 계산 제약 간의 순환 의존이 발생하면 `used before bound` 에러 및 비결정적 분기(Stuck terms)가 발생한다.

### Technique
번역기 $\mathcal{S}_{\mathrm{bind}}$ 단계는 전제를 원자 제약으로 분해하여 의존성 그래프 $G=(V,E)$를 구성한다. 
- 노드 $V$: 정렬 제약, 매칭 제약, 계산 제약
- 간선 $u \to v$: $v$가 요구하는 변수를 $u$가 최초 도입

이후 위상 정렬(Topological Sorting)을 수행하여 실행 순서를 획득하고, 변수 도입 제약(매칭 방정식 $x := t$)을 선행 배치(Front-loading)한다.

$$
\pi = \mathrm{TopoSort}(G), \qquad \mathrm{premises}' = \mathrm{FrontLoad}(\pi, \mathrm{premises})
$$

### Implementation Details (Edge-case Handling)
안정적인 스케줄링을 보장하기 위해 다음 4가지 엣지 케이스를 강제한다.
1. **Empty-term Guard:** 인자가 없는 타입 직렬화에서 `()` 출력을 물리적으로 차단.
2. **LetPr Promotion:** `LetPr`를 단순 불리언이 아닌 스케줄 가능한 매칭 전제(`:=`)로 승격.
3. **Explicit Variable Closure:** 바인딩 스케줄러에 의해 도입된 새 변수들을 규칙 상단의 `vars` 선언 집합에 강제로 삽입.
4. **Condition Order Discipline:** 조건절 출력 시 `:=` 매칭을 최우선으로 배치하고, 이후에 `type-ok` 및 `==` 가드를 출력하도록 고정.

### Effect
- 조건열 평가의 실행 가능성(Executability) 보장 및 자유 변수 공백 제거.
- 규칙 적용 경로의 결정론적 안정화로 등식 이론의 합류성(Confluence) 입증.

$$
\mathrm{WellBound}(\mathrm{premises}') \Rightarrow \mathrm{Executable} \land \mathrm{Confluent}
$$

---

## 5. Architecture Preservation & Reproducibility

본 번역 아키텍처는 원본 `translator.ml`의 파이프라인 형태(`prescan` $\to$ `header` $\to$ `translate` $\to$ `emit`)를 순수 함수 형태로 보존하면서 수학적 정합성을 달성했다.

생성된 `output.maude`의 무결성은 하드코딩된 보조 정리 없이 다음 `reduce` 질의를 통해 즉각적으로 재현(Reproduce) 및 검증된다.
1. Canonical constructor 기반 타입 판정 (`result Bool: true`)
2. `:=` 선행 바인딩을 갖는 `Def` 규칙의 미바인딩 오류 없는 환원
3. `eps` 중심 리스트/모노이드 연산의 정규형 수렴 (`result WasmTerminals: eps`)