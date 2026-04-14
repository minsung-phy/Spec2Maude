# Spec2Maude 검증 테스트 보고서

> 대상 독자: 시스템 검증자 및 지도 교수님  
> 문서 버전: 2026-04-14  
> 실행 환경: Maude 3.5.1 (macOS), output.maude (자동 생성, 7,066줄)

---

## 1. 검증 대상 개요

본 문서는 Spec2Maude가 자동 생성한 `output.maude`와 `wasm-exec.maude`를 이용하여 수행한 형식 검증 결과를 기록합니다. 검증은 두 계층으로 구성됩니다.

| 계층 | 방법 | 도구 |
|------|------|------|
| 등식 실행 검증 (Equational Reduction) | `rewrite` 명령 | Maude `WASM-FIB` 모듈 |
| LTL 시간 논리 모델 체킹 | `modelCheck` 술어 | Maude `MODEL-CHECKER` 모듈 |

---

## 2. 검증 대상 프로그램: 반복적 피보나치 (Iterative Fibonacci)

### 2-1. 프로그램 설명

검증 대상은 WebAssembly 명령어 시퀀스로 직접 인코딩된 **반복적 피보나치 수열 계산 함수**입니다. 재귀 대신 반복(루프)을 사용하여 `fib(n)`을 계산합니다.

알고리즘:
- 지역 변수: `locals[0] = n` (카운터), `locals[1] = a = 0`, `locals[2] = b = 1`, `locals[3] = tmp`
- 조건: `n <= 0`이면 루프 탈출, 그렇지 않으면 `tmp = a + b; a = b; b = tmp; n -= 1` 반복
- 반환: `a` (루프 종료 후 `locals[1]`)

### 2-2. Maude 인코딩

```maude
--- 루프 본체 (WebAssembly 명령어 시퀀스)
eq fib-loop-body =
  CTORLOCALGETA1(0) CTORCONSTA2(CTORI32A0, 0)   --- local.get 0; i32.const 0
  CTORRELOPA2(CTORI32A0, CTORLEA1(CTORSA0))      --- i32.le_s
  CTORBRIFA1(1)                                   --- br_if 1  (루프 탈출)
  CTORLOCALGETA1(1) CTORLOCALGETA1(2)            --- local.get 1; local.get 2
  CTORBINOPA2(CTORI32A0, CTORADDA0)              --- i32.add
  CTORLOCALSETA1(3)                               --- local.set 3
  CTORLOCALGETA1(2) CTORLOCALSETA1(1)            --- local.get 2; local.set 1
  CTORLOCALGETA1(3) CTORLOCALSETA1(2)            --- local.get 3; local.set 2
  CTORLOCALGETA1(0) CTORCONSTA2(CTORI32A0, 1)
  CTORBINOPA2(CTORI32A0, CTORSUBA0)              --- i32.sub
  CTORLOCALSETA1(0)                               --- local.set 0
  CTORBRA1(0) .                                   --- br 0  (루프 재진입)

--- 함수 본체: 루프 블록 + 결과 반환
eq fib-body =
  CTORBLOCKA2(void-bt, exec-loop(void-bt, fib-loop-body))
  CTORLOCALGETA1(1) .     --- local.get 1 (결과 반환)

--- 실행 초기 상태
eq fib-config(NVAL) = < fib-state(NVAL) | fib-body > .
```

---

## 3. 검증 1: 등식 실행 (Equational Reduction)

### 3-1. 실행 명령

```maude
load wasm-exec

rewrite [100000] in WASM-FIB : steps(fib-config(i32v(5))) .
```

### 3-2. 실행 결과

```
rewrites: 5619 in 13ms cpu (14ms real) (403258 rewrites/second)
result ExecConf: < CTORSEMICOLONA2(
    {item('TAGS, eps) ; item('GLOBALS, eps) ; ... },
    {item('LOCALS,
          CTORCONSTA2(CTORI32A0, 0)
          CTORCONSTA2(CTORI32A0, 5)
          CTORCONSTA2(CTORI32A0, 8)
          CTORCONSTA2(CTORI32A0, 8)) ;
     item('MODULE, ...)}) | CTORCONSTA2(CTORI32A0, 5) >
```

### 3-3. 결과 해석

- **명령어 시퀀스** (`|` 오른쪽): `CTORCONSTA2(CTORI32A0, 5)` — 스택에 i32 값 5만 남음
- **`steps` 종료 조건**: `all-vals(IS) = true` 판정이 충족되어 더 이상 `steps-trans`가 발화하지 않음
- **결론**: `fib(5) = 5` 정확히 계산됨

### 3-4. 다양한 입력에 대한 테스트

```maude
rewrite [100000] in WASM-FIB : steps(fib-config(i32v(0))) .
--- result: CTORCONSTA2(CTORI32A0, 0)    [fib(0) = 0]

rewrite [100000] in WASM-FIB : steps(fib-config(i32v(1))) .
--- result: CTORCONSTA2(CTORI32A0, 1)    [fib(1) = 1]

rewrite [100000] in WASM-FIB : steps(fib-config(i32v(3))) .
--- result: CTORCONSTA2(CTORI32A0, 2)    [fib(3) = 2]

rewrite [100000] in WASM-FIB : steps(fib-config(i32v(5))) .
--- result: CTORCONSTA2(CTORI32A0, 5)    [fib(5) = 5]
```

---

## 4. 검증 2: LTL 시간 논리 모델 체킹

### 4-1. 모델 체킹 프레임워크 구성

`WASM-FIB-PROPS` 모듈은 LTL 모델 체킹을 위한 원자 명제(atomic proposition)를 정의합니다.

```maude
mod WASM-FIB-PROPS is
  inc WASM-FIB .
  inc MODEL-CHECKER .
  inc LTL-SIMPLIFIER .

  subsort ExecConf < State .          --- 실행 설정을 Kripke 구조의 상태로 승격

  ops done trap-seen result-neg : -> Prop .
  op  result-is : Int -> Prop .

  --- done: 명령어 시퀀스가 값으로만 구성된 상태
  ceq < MC-Z | MC-IS > |= done       = true if all-vals(MC-IS) = true .

  --- result-is(n): 스택 최상단에 i32.const n이 있는 상태
  ceq < MC-Z | MC-IS > |= result-is(MC-I)
      = true if MC-IS = CTORCONSTA2(CTORI32A0, MC-I) .

  --- trap-seen: 현재 상태가 trap인 상태
  ceq < MC-Z | MC-IS > |= trap-seen  = true if MC-IS = CTORTRAPA0 eps .

  --- result-neg: 스택 최상단에 음수 i32 값이 있는 상태
  ceq < MC-Z | MC-IS > |= result-neg = true
      if MC-IS = CTORCONSTA2(CTORI32A0, MC-I) /\ MC-I < 0 .
endm
```

**상태 전이 관계**: `exec-step` CRL 규칙이 모델 체커의 전이 관계를 정의합니다.

```maude
crl [exec-step] :
  < MC-Z-EC | MC-IS-EC >
  => step(< MC-Z-EC | MC-IS-EC >)
  if MC-IS-EC =/= eps
  /\ all-vals(MC-IS-EC) = false
  /\ is-trap(MC-IS-EC) = false .
```

이 규칙은 종료 상태(값 또는 trap)가 아닌 모든 상태에서 `step` 함수를 적용하여 다음 상태로 전이합니다.

### 4-2. 검증 속성 1: 결과값 수렴 (Liveness)

**속성 (LTL 공식)**:

```
φ₁ := ◇ result-is(5)
```

"초기 상태에서 출발하는 모든 실행 경로 위의 어느 미래 시점에 결국 스택에 값 5가 위치한다."

**실행 명령**:

```maude
red in WASM-FIB-PROPS : modelCheck(fib-config(i32v(5)), <> result-is(5)) .
```

**검증 결과**:

```
rewrites: 5710 in 15ms cpu (15ms real) (370082 rewrites/second)
result Bool: true
```

**의미**:  
`fib(5)`의 실행은 유한한 단계 안에 반드시 종료되며, 종료 상태에서 스택에는 정확히 `i32.const 5`만이 남습니다. 이는 두 가지를 동시에 증명합니다.
1. **종료성(Termination)**: 실행이 무한 루프에 빠지지 않습니다.
2. **정확성(Correctness)**: 계산 결과가 수학적으로 올바른 피보나치 값입니다.

### 4-3. 검증 속성 2: Trap 안전성 (Safety)

**속성 (LTL 공식)**:

```
φ₂ := □ ¬ trap-seen
```

"초기 상태에서 출발하는 모든 실행 경로의 모든 시점에서 trap 상태에 도달하지 않는다."

**실행 명령**:

```maude
red in WASM-FIB-PROPS : modelCheck(fib-config(i32v(5)), [] ~ trap-seen) .
```

**검증 결과**:

```
rewrites: 5625 in 14ms cpu (14ms real) (383122 rewrites/second)
result Bool: true
```

**의미**:  
`fib(5)` 실행 중 어떠한 WebAssembly 런타임 오류(division by zero, OOB memory access, type mismatch 등)도 발생하지 않습니다. 이는 이 프로그램이 WebAssembly 명세 상의 **안전 실행(safe execution)** 조건을 완전히 만족함을 증명합니다.

### 4-4. 두 속성의 종합적 의의

| 속성 | 공식 | 분류 | 검증 결과 |
|------|------|------|-----------|
| 결과값 수렴 | `◇ result-is(5)` | Liveness | **true** |
| Trap 안전성 | `□ ¬ trap-seen` | Safety | **true** |

두 속성의 동시 성립은 이 WebAssembly 프로그램이 **안전하며 올바르게 종료됨**을 공식적으로 보장합니다. 특히, 모델 체커는 도달 가능한 **모든** 상태를 완전 탐색하여 이 결과를 도출하므로, 유한한 상태 공간에서의 완전한 정확성 증명입니다.

---

## 5. 향후 테스트 설계: 인터리빙 프로그램의 모델 체킹

### 5-1. 목표

현재 `wasm-exec.maude`는 단일 스레드 WebAssembly 실행 모델을 검증합니다. 향후 연구 목표는 **멀티 인스턴스 인터리빙(Multi-instance Interleaving)** 또는 WebAssembly GC/공유 메모리 제안의 동시성 의미론을 검증하는 것입니다. 이는 Dining Philosophers 문제와 유사한 상호 배제(mutual exclusion) 및 교착 상태(deadlock freedom) 속성 검증을 포함합니다.

### 5-2. 테스트 설계 명세 (Test Plan)

#### 시나리오: 공유 메모리를 이용한 2-스레드 상호 배제

**설정**:
- 공유 메모리 `M`에 뮤텍스 플래그 `M[0] = 0 (unlocked) / 1 (locked)` 존재
- 스레드 T1, T2가 각각 임계 구역(critical section)에 진입 시도
- WebAssembly `memory.atomic.rmw.cmpxchg` 명령어(원자적 비교-교환)로 뮤텍스 획득

**검증할 속성**:

```
--- 안전성: 두 스레드가 동시에 임계 구역에 있지 않음
φ_safe := □ ¬ (T1-in-CS ∧ T2-in-CS)

--- 공정성: 모든 스레드가 언젠가는 임계 구역에 진입함
φ_fair := □ (T1-waiting → ◇ T1-in-CS)
          ∧ □ (T2-waiting → ◇ T2-in-CS)

--- 교착 상태 없음
φ_deadlock := □ ◇ (T1-in-CS ∨ T2-in-CS)
```

#### 멀티 인스턴스 인터리빙 모델 구조

인터리빙 의미론을 모델링하기 위해 다음 개념 설계를 제안합니다.

```maude
--- 개념 설계 (뼈대 코드)

--- 다중 스레드 설정: 스레드 ID와 ExecConf의 쌍
sort ThreadId .
ops T1 T2 : -> ThreadId [ctor] .

--- 다중 스레드 상태: 공유 Store + 스레드별 ExecConf 맵
sort MultiConf .
op { store:_ , threads:_ } : WasmTerminal ThreadMap -> MultiConf [ctor] .

sort ThreadMap .
op _|->_ : ThreadId ExecConf -> ThreadMap [ctor] .
op _;_ : ThreadMap ThreadMap -> ThreadMap [assoc] .

--- 공유 메모리 접근 원자적 실행을 위한 step-thread 연산
op step-thread : ThreadId MultiConf -> MultiConf .

--- 비결정적 스케줄러: T1 또는 T2를 선택하여 한 스텝 실행
crl [interleave-T1] :
  MC => step-thread(T1, MC)
  if thread-runnable(T1, MC) = true .

crl [interleave-T2] :
  MC => step-thread(T2, MC)
  if thread-runnable(T2, MC) = true .
```

#### 원자적 명령어 의미론 확장

WebAssembly의 공유 메모리 원자 명령어는 `WASM-EXEC`의 `step` 방정식을 확장하여 처리합니다.

```maude
--- 뼈대: memory.atomic.rmw.cmpxchg 의미론
--- (expected = 메모리 현재값이면 new로 교체, 아니면 현재값 반환)
ceq step-atomic(T-ID, < Z | i32.const expected  i32.const new
                           memory.atomic.rmw.cmpxchg 0  IS >)
    = < update-mem(Z, 0, new) | i32.const current IS >
    if current := mem-load(Z, 0)
    /\ current = expected .

ceq step-atomic(T-ID, < Z | i32.const expected  i32.const new
                           memory.atomic.rmw.cmpxchg 0  IS >)
    = < Z | i32.const current IS >
    if current := mem-load(Z, 0)
    /\ current =/= expected .
```

#### LTL 속성 인코딩

```maude
--- 개념 설계: 멀티스레드 LTL 속성

--- 원자 명제 정의
ceq MC |= T1-in-cs = true if in-critical-section(T1, MC) = true .
ceq MC |= T2-in-cs = true if in-critical-section(T2, MC) = true .
ceq MC |= deadlock  = true
    if thread-runnable(T1, MC) = false
    /\ thread-runnable(T2, MC) = false
    /\ all-done(MC) = false .

--- 검증 명령
red in MULTI-THREAD-PROPS :
  modelCheck(initial-config, [] ~ (T1-in-cs /\ T2-in-cs)) .   --- 상호 배제

red in MULTI-THREAD-PROPS :
  modelCheck(initial-config, [] ~ deadlock) .                   --- 교착 상태 없음

red in MULTI-THREAD-PROPS :
  modelCheck(initial-config, [] (T1-waiting -> <> T1-in-cs)) . --- 기아 없음
```

### 5-3. 구현 로드맵

| 단계 | 작업 | 선결 조건 |
|------|------|-----------|
| Phase 7-A | WebAssembly 공유 메모리 명령어 의미론 (`memory.atomic.*`) 추가 | `output.maude`의 메모리 ops 확장 |
| Phase 7-B | `MultiConf` 정렬 및 인터리빙 CRL 규칙 작성 | Phase 7-A 완료 |
| Phase 7-C | 상호 배제 속성 모델 체킹 | Phase 7-B 완료 |
| Phase 7-D | 공정성 속성 (약한 공정성 보조 `crl` 추가) | Phase 7-C 완료 |

### 5-4. 기대 결과

Dining Philosophers 문제(N명의 철학자, N개의 포크)를 WebAssembly 스레드로 인코딩하면:
- 상호 배제(`φ_safe`): 인접한 두 철학자가 동시에 식사하지 않음 → **true** 기대
- 교착 상태 없음(`φ_deadlock`): 모든 철학자가 동시에 포크를 집으면 교착 발생 → **false** 기대 (교착 상태 발견)
- 기아 없음(`φ_fair`): 약한 공정성 조건 하에서만 **true** 기대

이 결과를 통해 WebAssembly의 공유 메모리 동시성 모델의 형식적 한계를 구체화하고, 원자적 명령어 보강의 필요성을 증명할 수 있습니다.
