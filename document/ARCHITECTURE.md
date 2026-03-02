# Spec2Maude translator의 논리 아키텍처 및 구현 명세서

<div align="right">
  <strong>포항공과대학교 SVLab 이민성</strong><br>
  <strong>2026.02.24</strong>
</div>

## 1. Introduction
본 문서는 WebAssembly(Wasm) 명세 언어인 Spectec의 AST(Abstract Syntax Tree)를 Maude의 Algebraic Specification으로 변환하기 위한 논리적 매핑 규칙(Mapping Rules) 및 상세 구현 로직을 기술합니다.
본 프로젝트는 실행 효율성과 명세의 엄밀함을 동시에 확보하여 Wasm의 정형 검증을 자동화하는 것을 목표로 합니다.

## 2. Pre-defined Infrastructure
변환된 Maude 코드가 논리적으로 무결하게 작동하기 위해 사전에 정의된 도메인 특화 언어(DSL) 환경입니다.

### 2.1 Data Structures (Sorts)
Maude의 모든 연산은 Sort를 기반으로 하며, 다음과 같은 기초 Sort가 정의되어 있습니다.

* **WasmTerminal** : Wasm의 가장 atomic한 값(숫자 리터럴, 생성자) 및 단일 명령어(Instruction)을 나타내는 sort입니다.
* **WasmTerminals** : 명령어 리스트(instr*)와 같이 여러 터미널의 시퀀스를 처리하기 위한 복수형 sort입니다.
* **WasmType** : Wasm의 타입 규격(numtype, valtype, instr 등)을 정의하는 sort입니다.
* **typecheck(T, TY)** : 값 T가 타입 TY의 규격을 만족하는지 판별하여 Bool 값을 반환하는 핵심 인터페이스입니다.

### 2.2 Symbolic Rules
* **메타 함수 ($)** : SpecTec의 내장 함수임을 명시하기 위해 Maude 연산자 앞에 $ 접두사를 부여합니다. (예: $size, $bits)
* **식별자 정규화 (Sanitization)** : Maude의 Mixfix 문법과의 충돌을 방지하기 위해 _IDX와 같은 생성자를 -IDX로 치환합니다.

## 3. Syntax Tranformation : TypD
Spectec의 syntax 정의는 Maude에서 타입 카테고리와 구체적 데이터(생성자)를 분리하여 선언한 뒤, typecheck 등식을 통해 이들의 관계를 규명합니다.

### 3.1 Basic Mapping
가장 atomic한 형태의 구문 정의로, 새로운 타입을 선언하고 이에 속하는 상수(Constant) 생성자를 정의합니다.

* **변환 규칙** : 타입 이름은 op T : → WasmType으로, 개별 생성자는 op C : → WasmTerminal로 매핑합니다.

* **변환 로직** : eq typecheck(C, T) = ture .를 통해 직접적인 소속 관계를 명시합니다.

* **변환 예시** :
  ```spectec
  syntax null = NULL
  ```

  ```maude
  op null : -> WasmType .
  op NULL : -> WasmTerminal .
  eq typecheck(NULL, null) = true .
  ```

### 3.2 Numerical Constraints
파라미터를 가지며 수학적 범위를 제약하는 타입(uN, sN  등)은 Maude의 조건부 등식(ceq)으로 변환합니다.

* **변환 로직** : Spectec의 범위를 if 절의 산술 제약 조건으로 매핑합니다.

* **변환 예시** :
  ```spectec
  syntax uN(N) = 0 | ... | $nat$(2^N-1)
  ```

  ```maude
  var N : Nat .
  var N_UN : Nat . 
  var i : Int .

  op uN : WasmTerminal -> WasmType .
  ceq typecheck(i, uN(N_UN)) = true
    if typecheck(N_UN, N) /\ 0 <= i /\ i < 2 ^ N_UN .
  ```

### 3.3 Parameterized Constructors
일부 명령어는 특정 수치 타입(i32, i64 등)이나 추가 옵션(sx 등)에 따라 그 성격이 결정됩니다. 이를 위해 타입을 인자로 받아 새로운 카테고리를 만드는 '타입 생성자'와 검증 로직을 단순화하는 '논리 전파' 기법을 사용합니다.

* **변환 규칙** : 타입 생성자 및 구조적 분해
  Spectec에서 `binop_(numtype)`과 같이 정의된 구조는 Maude에서 단순한 상수가 아닌, 인자를 받아 새로운 타입을 생성하는 Operator로 정의됩니다.
  * **타입 생성자 (Type Constructor)**: `binop-`와 같은 카테고리를 `WasmType`을 반환하는 함수로 선언하여, `binop-(i32)`나 `binop-(i64)`와 같이 구체적인 컨텍스트를 동적으로 생성합니다.
  * **논리 전파 (Boolean Propagation)**: 명령어의 타당성을 검사할 때, 상위 명령어의 `typecheck` 결과를 하위 구성 요소들의 `typecheck` 결과들의 논리곱(`/\`)으로 정의합니다. 이는 `if` 문(`ceq`)을 사용하는 것보다 리라이팅 엔진의 탐색 효율을 극대화합니다.

* **변환 예시** :
  DIV 명령어는 부호 여부(sx)와 데이터 타입(numtype)에 따라 결정됩니다.
  ```spectec
  syntax binop_(numtype)
  syntax binop_(Inn) = DIV sx   // 부호(sx)를 인자로 받는 나눗셈 연산
  ```

  ```maude
  --- 1. 카테고리를 생성하는 타입 생성자 정의 (WasmType을 반환)
  op binop- : WasmTerminal -> WasmType .

  --- 2. 매개변수(부호)를 가질 수 있는 명령어(Terminal) 정의
  op DIV _ : WasmTerminal -> WasmTerminal .

  --- 3. 등식(eq)을 이용한 논리 전파 구현
  eq typecheck(DIV SX, binop-(INN)) = 
    typecheck(INN, Inn) /\ 
    typecheck(SX, sx) .
  ```

* **설계의 장점** :
  * **계층적 검증** : `DIV` 명령어의 유효성을 검사할 때, 자신이 직접 로직을 수행하지 않고 `INN`이 `Inn`인지, `SX`가 `sx`인지를 확인하는 하위 로직으로 책임을 분산(Delegation)합니다.
  * **결과 자동 전파** : `eq`를 사용함으로써 하위 검사 중 하나라도 `false`를 반환하면 전체 결과가 즉시 `false`로 수렴됩니다. 이는 Maude의 연산 속도를 비약적으로 향상시킵니다.

### 3.4 Union Types
여러 하위 타입을 포함하는 카테고리(예 : valtype)는 결과 값을 하위 타입 체크 함수로 위임(Delegation)하는 eq 문장으로 정의합니다.

* **변환 로직** : 상위 타입 체크 식을 하위 타입 체크 식과 동치(Equivalent)로 정의합니다.

* **변환 예시** :
  ```spectec
  syntax valtype/syn = | numtype | ...
  ```

  ```maude
  op valtype : -> WasmType .
  var VALTYPE : WasmTerminal .
  --- 결과값을 numtype 체크로 위임하여 전파
  ceq typecheck(VALTYPE, valtype) = typecheck(VALTYPE, numtype) .
  ```

## 4. Function Transformation : DecD
SpecTec에서 함수 정의(def)는 Maude의 Pattern Matching 기반 연산 로직으로 변환됩니다.

### 4.1 함수 시그니처 선언
* **변환 로직** : Spectec의 def 시그니처를 Maude의 op 선언문으로 Mapping 합니다.

* **추상화** : SpecTec에서의 구체적인 타입(예 : numtype, nat)은 Maude의 범용 소트인 WasmTerminal로 추상화하여 선언합니다.
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
* **규칙** : 함수의 각 Clause는 독립적인 eq 문장으로 생성되어 Maude에서 즉각적인 치환이 가능하게 합니다.

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

## 5. Conclusion
본 변환 시스템은 SpecTec의 추상적인 수학적 정의를 실행 가능한 논리 체계인 Maude로 정교하게 매핑합니다. 특히 조건부 등식(ceq)을 통한 수치 제약과 등식(eq)을 통한 명령어 논리 전파를 전략적으로 분리함으로써, WebAssembly 명세(1.1~1.3)를 오류 없이 정형 검증 환경에 즉시 적용할 수 있는 자동화 파이프라인을 구축하였습니다.