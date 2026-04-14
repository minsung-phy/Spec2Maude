# Spec2Maude 핵심 아키텍처 결정 사항

> 대상 독자: 논문 리뷰어 (PLDI/VMCAI) 및 지도 교수님  
> 문서 버전: 2026-04-14

---

## 서론

Maude 시스템은 강력한 등식 재작성 로직(Equational Rewriting Logic) 엔진을 제공하지만, WebAssembly의 가변 길이 명령어 시퀀스와 복합 상태 구조를 정확하게 인코딩하는 과정에서 두 가지 근본적인 기술적 장벽에 직면합니다. 본 문서는 이 두 장벽을 극복하기 위해 채택된 설계 결정과 그 학술적 근거를 기술합니다.

---

## 결정 사항 A. 평가 문맥 래퍼(Evaluation Context Wrapper) 도입

### 1. 문제 배경: Kind-level 에러와 가변 길이 시퀀스

WebAssembly의 소형 단계 의미론(Small-Step Operational Semantics)은 구조적 규칙을 통해 명령어 시퀀스 내부의 임의 위치로 평가를 위임합니다. 예를 들어, 레이블 내부 실행에 대한 구조적 규칙은 다음과 같이 표현됩니다.

```
z ; instr* ~> z' ; instr'*
───────────────────────────────────────────────────── (Step/ctxt-label)
z ; LABEL_n{instr_0*} instr* ~> z' ; LABEL_n{instr_0*} instr'*
```

Maude의 `WasmTerminals` 시퀀스 타입은 `op eps : -> WasmTerminals`와 `op __ : WasmTerminal WasmTerminals -> WasmTerminals [assoc id: eps]`로 정의됩니다. 이 `assoc id:` 속성 때문에, 패턴 `LABEL_n{...} INSTRS`에서 `INSTRS : WasmTerminals`가 `WasmTerminal` kind와 `WasmTerminals` kind를 동시에 걸치는 **kind-level ambiguity**가 발생합니다.

구체적으로, 다음과 같은 crl 규칙을 작성하면 Maude 파서가 이를 거부합니다.

```maude
--- 의도한 규칙 (실제로는 작동하지 않음)
crl [ctxt-label] :
  < Z | CTORLABELA3(N, IS0, IS_INNER) IS_REST >
  => < Z' | CTORLABELA3(N, IS0, IS_INNER') IS_REST >
  if < Z | IS_INNER > => < Z' | IS_INNER' > .
```

`IS_INNER`의 타입이 `WasmTerminals`인데, 이것이 `CTORLABELA3`의 세 번째 인자 (타입 `WasmTerminal`)와 `WasmTerminal`의 `assoc` 시퀀스에 동시에 매칭되어야 하므로, kind-level에서 타입 체계가 붕괴됩니다.

### 2. 해결책: 런타임 래퍼 연산자

이 문제를 해결하기 위해, **레이블·프레임·핸들러의 내부 시퀀스를 `WasmTerminal` 한 개로 포장하는 전용 래퍼 연산자**를 도입합니다.

```maude
op exec-label   : Nat WasmTerminals WasmTerminals -> WasmTerminal [ctor] .
op exec-loop    : WasmTerminal WasmTerminals -> WasmTerminal [ctor] .
op exec-frame   : Nat WasmTerminal WasmTerminals -> WasmTerminal [ctor] .
op exec-handler : Nat WasmTerminal WasmTerminals -> WasmTerminal [ctor] .
```

이 연산자들의 반환 타입은 `WasmTerminal`이므로, `WasmTerminals` 시퀀스의 원소로 자연스럽게 배치될 수 있습니다. 예를 들어, 피보나치 함수의 루프 본체는 다음과 같이 인코딩됩니다.

```maude
eq fib-body =
  CTORBLOCKA2(void-bt, exec-loop(void-bt, fib-loop-body))
  CTORLOCALGETA1(1) .
```

`exec-loop(...)` 자체가 `WasmTerminal` 하나이므로, 바깥 블록의 `CTORBLOCKA2`의 두 번째 인자(타입 `WasmTerminal`)에 적합하게 들어맞습니다.

### 3. Heating/Cooling 패턴

래퍼 연산자는 Maude의 heating/cooling 원리를 구현하기 위한 보조 연산자(`restore-*`)와 함께 작동합니다.

```maude
op restore-label   : ExecConf Nat WasmTerminals WasmTerminals -> ExecConf .
op restore-frame   : ExecConf Nat WasmTerminal  WasmTerminals -> ExecConf .
op restore-handler : ExecConf Nat WasmTerminal  WasmTerminals -> ExecConf .
```

**Heating** (레이블 내부로 `step` 위임):

```maude
ceq step(< Z | exec-label(N, IS0, IS_INNER) IS_REST >)
    = restore-label(step(< Z | IS_INNER >), N, IS0, IS_REST)
    if IS_INNER =/= eps /\ all-vals(IS_INNER) = false /\ is-trap(IS_INNER) = false .
```

**Cooling** (실행 완료 후 래퍼 복구):

```maude
eq restore-label(< ZN | IS_INNER' >, N, IS0, IS_REST)
   = < ZN | exec-label(N, IS0, IS_INNER') IS_REST > .
```

이 방식은 WebAssembly 명세의 구조적 규칙을 Maude의 타입 시스템 제약 없이 충실하게 인코딩합니다.

### 4. 학술적 의의

이 설계는 Maude 기반 언어 의미론 연구에서 잘 알려진 **K-Framework의 evaluation context** 개념을 Maude의 sort 시스템 제약에 맞게 변형한 것입니다. 기존 K-Framework 접근법과의 차이점은, K는 별도의 configuration cell 추상화를 제공하는 반면, 본 설계는 Maude의 native sort 시스템 위에서 동일한 효과를 달성한다는 점입니다.

---

## 결정 사항 B. 상태 전이 규칙의 Eq/Ceq 인코딩 (CRL 최소화)

### 1. 문제 배경: Assoc-ID 리스트 매칭의 변수명 충돌

Maude의 `assoc id:` 속성을 가진 연산자에서, 동일한 이름의 변수가 서로 다른 연산자의 등식에서 공유될 때 **coherence checker**가 잘못된 상호작용(false interaction)을 감지합니다.

예를 들어, 다음 두 방정식이 같은 모듈에 공존한다고 가정합니다.

```maude
--- 방정식 1: all-vals 판정
ceq all-vals(V IS) = all-vals(IS) if is-val(V) = true .

--- 방정식 2: step 적용
ceq step(< Z | V IS >) = < Z | RESULT IS > if is-val(V) = true .
```

`IS`가 두 방정식 모두에서 `WasmTerminals`의 assoc tail variable로 사용될 때, Maude의 coherence checker는 이 둘 사이에 interaction을 의심하여 내부 lemma를 생성합니다. 이 lemma가 증명 불가능할 경우, **특정 방정식이 정상적인 입력에 대해 점화(fire)되지 않는** 심각한 버그가 발생합니다.

실제로, 이 버그는 `fib(5)` 실행이 473 rewrites에서 정지하는 현상으로 나타났습니다: `LOCAL.GET`에 선행 값들이 있을 때 step 방정식이 매칭되지 않았습니다.

### 2. 해결책: 그룹별 고유 변수명 접두사

각 연산자 그룹에 고유한 접두사를 할당하여 변수명이 절대 충돌하지 않도록 강제합니다.

```maude
--- step 방정식 전용 변수
vars ST-Z ST-ZN ST-X ST-VAL ST-NT ST-OP : WasmTerminal .
vars ST-VALS ST-IS : WasmTerminals .

--- all-vals 방정식 전용 변수  
var  AV-V : WasmTerminal .
var  AV-IS : WasmTerminals .

--- is-val 방정식 전용 변수
var  IV-V : WasmTerminal .
var  IV-IS : WasmTerminals .

--- is-trap 방정식 전용 변수
var  IT-V : WasmTerminal .
var  IT-IS : WasmTerminals .

--- restore-label 방정식 전용 변수
vars RL-ZN : WasmTerminal .
var  RL-ISBN RL-IS0 RL-IS : WasmTerminals .
```

이 변수명 격리는 coherence checker가 서로 다른 연산자의 방정식을 독립적으로 처리하도록 보장합니다.

### 3. Equational Reduction 전략: CRL 최소화

두 번째 핵심 결정은 **모든 단일 스텝 동작을 `crl` 대신 `eq`/`ceq`로 인코딩**하는 것입니다.

#### 동기

Maude의 `crl` (conditional rewrite rule)은:
- **비효율적**: 규칙 매칭이 등식 정규화(equational normalization)보다 느립니다.
- **조건 제약**: `crl`의 조건절은 변수 바인딩을 포함할 수 없으므로, 산술 결과를 바인딩하는 Let-전제(`LetPr`)를 직접 표현하기 어렵습니다.
- **비결정성 노출**: 복수의 `crl`이 매칭될 수 있을 때 전략(strategy)을 명시해야 합니다.

#### 설계

단일 스텝 동작은 모두 `step : ExecConf -> ExecConf`의 `eq`/`ceq` 방정식으로 정의합니다.

```maude
--- Step-pure 예시
eq step(< ST-Z | CTORUNREACHABLEA0 ST-IS >) = < ST-Z | CTORTRAPA0 ST-IS > .

--- Step-read 예시 (조건부)
ceq step(< ST-Z | CTORLOCALGETA1(ST-X) ST-IS >)
    = < ST-Z | ST-VAL ST-IS >
    if ST-VAL := $local(ST-Z, ST-X) .
```

그리고 **단 하나의 `crl`** 만으로 다단계 축소(multi-step reduction)를 구동합니다.

```maude
crl [steps-trans] :
  steps(< TS-Z | TS-IS >)
  => steps(step(< TS-Z | TS-IS >))
  if TS-IS =/= eps
  /\ all-vals(TS-IS) = false
  /\ is-trap(TS-IS) = false .
```

`step(EC)` 호출은 등식 정규화 과정에서 완전히 평가됩니다. 즉, `crl`의 조건(`if`)을 평가하기 위해 `step(EC)`를 equational normalization으로 계산하고, 그 결과를 다시 `steps(...)` 안에 넣어 다음 `crl` 발화를 유도합니다. 이는 다음 성질을 보장합니다.

- **합류성(Confluence)**: 각 상태에서 `step`이 유일한 결과로 수렴하므로, 전체 `steps` 계산이 결정적입니다.
- **종료성(Termination)**: `steps-trans`는 상태가 변하지 않는 한(값만 남거나 trap) 계속 발화합니다. `is-trap` 및 `all-vals` 판정이 종료 조건을 제공합니다.

#### LTL 모델 체킹과의 연동

LTL 모델 체커는 `crl` 규칙으로 정의되는 상태 전이 관계를 탐색합니다. 이를 위해 `steps-trans`와는 별도로 `exec-step`을 제공합니다.

```maude
crl [exec-step] :
  < MC-Z-EC | MC-IS-EC >
  => step(< MC-Z-EC | MC-IS-EC >)
  if MC-IS-EC =/= eps
  /\ all-vals(MC-IS-EC) = false
  /\ is-trap(MC-IS-EC) = false .
```

`exec-step`은 `ExecConf` 위에서 직접 발화하여, 모델 체커가 `steps(...)` 래퍼 없이 원시 상태 그래프를 탐색할 수 있도록 합니다.

### 4. 학술적 의의

이 설계는 **Rewriting Logic Semantics (RLS)** 의 표준적 관행, 즉 연산 규칙(equational axioms)과 전이 규칙(rewrite rules)의 명확한 분리 원칙을 준수합니다 (Meseguer, 1992). 구체적으로, WebAssembly의 소형 단계 의미론에서 **순수한 계산 규칙**(Step-pure, Step-read)과 **상태 변이 규칙**(Step)을 모두 equational theory로 흡수하고, CRL 계층은 오직 전이 그래프 탐색을 위한 최소한의 틀(framework)로만 사용합니다.

이는 Maude 기반 언어 의미론 연구에서 일반적으로 사용되는 "전부 CRL로 작성" 방식에 비해:
1. **성능**: equational normalization이 crl matching보다 수배 빠릅니다.
2. **정확성**: assoc-id 변수 충돌을 원천 차단합니다.
3. **검증 용이성**: `step`이 confluent한 총함수이므로, 모델 체킹의 상태 공간 폭발 없이 안전 속성을 검증할 수 있습니다.
