# Spec2Maude translator의 논리 아키텍처 및 구현 명세서

<div align="right">
  <strong>포항공과대학교 SVLab 이민성</strong><br>
  <strong>2026.02.24</strong>
</div>

## 1. Introduction
본 문서는 WebAssembly(Wasm) 명세 언어인 Spectec의 Abstract Syntax Tree(AST)를 Maude의 Algebraic Specification으로 translate 하기 위한 논리적 Mapping Rules 및 구현 상세를 기술합니다.

## 2. Pre-defined Infrastructure
변환된 Maude 코드가 논리적으로 무결하게 작동하기 위해 사전에 정의된 도메인 특화 언어(DSL) 환경입니다.

### 2.1 Data Structures
Maude의 모든 연산은 Sort를 기반으로 하며, 다음과 같은 기초 Sort가 정의되어 있습니다.

* **WasmTerminal** : Wasm의 가장 atomic한 값(숫자 리터럴, 생성자 등)을 나타내는 소트입니다.
* **WasmType** : Wasm의 타입을 정의하는 소트입니다.
* **typecheck(T, TY)** : 값 T가 타입 TY의 규격을 만족하는지 판별하는 핵심 인터페이스 연산자입니다.

### 2.2 예약어 및 심볼링 규칙
* **메타 함수 식별자 ($)** : SpecTec의 내장 함수임을 명시하기 위해 Maude 연산자 앞에 $ 접두사를 부여합니다.
* **식별자 정규화 (Sanitization)** : Maude의 Mixfix 문법과의 충돌을 방지하기 위해 _IDX와 같은 생성자를 -IDX로 치환합니다.

## 3. Syntax Tranformation : TypD
Spectec의 syntax 정의는 Maude에서 타입 선언, 생성자 선언, 소속 관계 정의의 3단계 등식으로 구조화됩니다.

### 3.1 일반 타입 매핑
* **변환 규칙** : 타입 이름은 op T : → WasmType으로, 개별 생성자는 op C : → WasmTerminal로 매핑합니다.
* **변환 예시** :
  ```spectec
  syntax null = NULL
  ```

  ```maude
  op null : -> WasmType .
  op NULL : -> WasmTerminal .
  eq typecheck(NULL, null) = true .
  ```

### 3.2 복합 및 합집합 타입 (Union Types)

* **변환 규칙** : 일부 Spectec syntax는 새로운 atomic한 값을 정의하지 않고, 이미 정의된 다른 타입들을 하나의 카테고리로 묶어주는 Union Type의 성격을 가집니다. 변환기는 이를 Conditional Equation(ceq)으로 변환하여 타입 간의 논리적 포함 관계를 구현합니다.
* **변환 예시** :
  ```spectec
  syntax valtype/syn = | numtype | ...
  ```

  ```maude
  op valtype : -> WasmType .
  var VALTYPE : WasmTerminal .
  ceq typecheck(VALTYPE, valtype) = true if typecheck(VALTYPE, numtype) .
  ```

* **상세 설계 로직**
  * **추상화 계층 유지** : valtype을 개별 생성자(I32, F32 등)와 직접 연결하지 않고, 중간 카테고리인 numtype과의 관계만 정의합니다. 이는 명세의 계층 구조를 보존하여 유지보수성을 높입니다.
  * **검증 권한 위임** : 어떤 값(VALTYPE)이 valtype인지 확인하는 연산은, 내부적으로 해당 값이 numtype인지를 먼저 검사하도록 위임됩니다. 만약 numtype 체크가 true를 반환하면, 조건부 방정식에 의해 valtype 체크 역시 자동으로 true가 됩니다.
  * **확장성** : 이후 명세에 새로운 하위 타입(예: rectype)이 추가되더라도, valtype에 대한 새로운 ceq 라인만 추가하면 기존 로직의 수정 없이 타입 시스템을 확장할 수 있습니다.

## 4. Function Transformation : DecD

SpecTec에서 특정 값을 계산하거나 타입을 판별하는 **함수 정의(def)**는 Maude의 Pattern Matching 기반의 연산 로직으로 변환됩니다.

### 4.1 함수 시그니처 선언

함수의 실제 로직을 정의하기 전, Maude가 해당 함수를 인식할 수 있도록 연산자(op) 형식을 선언합니다.

* **변환 로직** : Spectec의 def 시그니처를 Maude의 op 선언문으로 Mapping 합니다.
* **타입의 추상화** : SpecTec에서의 구체적인 타입(예 : numtype, nat)은 Maude의 범용 소트인 WasmTerminal로 추상화하여 선언합니다.
* **이유** : Maude가 Pattern Matching을 수행할 때, 다양한 형태의 항(Term)을 유연하게 입력받고 결과로 반환할 수 있도록 하기 위함입니다.
* **예시** :
  ```spectec
  def $size(numtype) : nat
  ```

  ```maude
  op $size : WasmTerminal -> WasmTerminal .
  var VARNUMTYPE : WasmTerminal . --- numtype
  ```

### 4.2 함수 로직 구현

선언된 시그니처를 바탕으로, 실제 입력값에 따른 결과값을 eq로 정의합니다.

* **패턴 매칭 적용** : 함수의 각 Clause는 독립적인 eq 문장으로 생성됩니다.
* **작동 원리** : Maude는 $size(…)라는 호출을 만나면 선언된 op 정보를 확인하고, 정의된 eq 패턴들 중 일치하는 것을 찾아 결과값으로 치환합니다.
* **예시** :
  ```spectec
  def $size(I32) = 32
  def $size(I64) = 64
  def $size(F32) = 32
  def $size(F64) = 64
  ```

  ```maude
  eq $size(I32) = 32 .
  eq $size(I64) = 64 .
  eq $size(F32) = 32 .
  eq $size(F64) = 64 .
  ```

## 5. Rule Transformation : IfPr

수치 범위 제약이나 전제 조건이 포함된 명세는 Maude의 논리적 전제 조건(Premise)으로 합성됩니다.

### 5.1 수치 범위 제약

SpecTec에서 un(N)과 같이 파라미터를 가지는 타입은 단순한 이름 비교가 아니라, 해당 값이 특정 수학적 범위를 만족하는지 검증해야 합니다.

* **변환 규칙** : SpecTec의 수치 범위 정의를 Maude의 산술 연산 체계로 변환하여 조건부 방정식(ceq)의 조건절로 Mapping 합니다.
* **논리적 검증** : 어떤 값 i가 타입 uN(N_UN)에 속하는지 판단할 때, Maude는 해당 값이 0 ≤ i < 2^N이라는 Numerical Constraint를 만족하는지 계산합니다.
* **예시** :
  ```spectec
  syntax uN(N) = 0 | ... | $nat$(2^N-1)
  ```

  ```maude
  ceq typecheck(i, uN(N_UN)) = true 
    if typecheck(N_UN, N) /\ 0 <= i  /\ i < 2 ^ N_UN . 
  ```

### 5.2 논리 연산자 및 전제 조건 합성

* **규칙** : SpecTec의 논리곱은 Maude의 /\ 연산자로 전사되며, 중첩된 IfPr 노드들은 Maude의 조건절(if...) 내부에서 선형적으로 결합됩니다.

## 6. 결론 (Conclusion)

본 번역 시스템은 SpecTec의 추상적인 수학적 정의를 Maude라는 정밀한 논리 체계로 전이시키는 통합 변환 로직을 제공합니다. 이를 통해 WebAssembly 명세의 변경 사항을 정형 검증 환경에 즉각적으로 반영하고 실행할 수 있는 자동화된 파이프라인을 구축하였습니다.