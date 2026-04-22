# Baseline Conditional Rule 실험 보고서

## 1. 시작 배경

0421 미팅에서 교수님께서 제안하신 방향은 다음과 같았다.

- `-- Step:`이 붙은 rule에 대해
- 먼저 heating/cooling rule을 쓰지 않고
- direct conditional rule로 1:1 변환하는 baseline을 만든 뒤
- 이 baseline과 heating/cooling 기반 translator의 결과 및 실행 시간을 비교해 보자는 것이다.

이에 따라 기존 `translator.ml`과 별도로 baseline 전용 translator인 `translator_bs.ml`를 만들었고, baseline용 harness인 `wasm-exec-bs.maude`도 따로 분리했다.

baseline의 목표는 다음과 같다.

- 느려도 correct한 기준선 확보
- manual override 없이 direct conditional rule만으로 실행 가능한지 확인
- 이후 heating/cooling 기반 translator와 model checking 성능/동작 비교

## 2. 실험 구성

### 2.1 baseline translator

새로 만든 baseline translator의 방향은 다음과 같다.

- `-- Step:`이 붙은 source rule을 direct conditional `crl`로 변환
- heating/cooling rule은 사용하지 않음
- static judgement 참조는 baseline 기준으로 `mb/cmb`가 아니라 `eq/ceq ... = valid`, 조건에서는 `... == valid`

생성 대상이 되는 source `-- Step:` rule은 총 5개였다.

- `Steps/trans`
- `Step/ctxt-instrs`
- `Step/ctxt-label`
- `Step/ctxt-handler`
- `Step/ctxt-frame`

baseline output에서는 이 5개를 모두 direct rule로 생성했다.

- `steps-trans`
- `step-ctxt-instrs`
- `step-ctxt-label`
- `step-ctxt-handler`
- `step-ctxt-frame`

### 2.2 baseline harness

`wasm-exec-bs.maude`는 다음 원칙으로 구성했다.

- `output_bs.maude`를 load
- fib benchmark/property module만 유지
- 기존 `wasm-exec.maude`에 있던 manual `step-*` override 제거
- `restore-*`, heating/cooling 의존 조각 제거

즉 baseline은 가능한 한 “translator가 직접 생성한 conditional rule만으로 실행되는가”를 보기 위한 구성이다.

## 3. 실험 과정

### 3.1 전체 fib baseline 실행

먼저 baseline으로 fib 전체를 바로 실행했다.

실행 명령:

```maude
rewrite [10000] in WASM-FIB-BS : steps(fib-config(i32v(5))) .
red in WASM-FIB-BS-PROPS : modelCheck(fib-config(i32v(5)), <> result-is(5)) .
red in WASM-FIB-BS-PROPS : modelCheck(fib-config(i32v(5)), [] ~ trap-seen) .
```

결과:

- 세 명령 모두 `Fatal error: stack overflow`

이 시점에서 baseline은 fib 전체를 돌리지 못했다.

### 3.2 작은 단일 step으로 축소 실험

fib 전체가 아니라, 아주 작은 단일 step에서도 같은 현상이 나는지 확인했다.

정상 종료한 예:

```maude
rew in WASM-FIB-BS : step(< fib-state(i32v(1)) | CTORNOPA0 >) .
```

결과:

- 정상 종료
- 결과는 `eps`

반면 아주 작은 singleton `Step-read`는 바로 실패했다.

```maude
rew in WASM-FIB-BS : step(< fib-state(i32v(1)) | CTORLOCALGETA1(1) >) .
rew in WASM-FIB-BS : step(< fib-state(i32v(1)) | CTORGLOBALGETA1(1) >) .
```

결과:

- 둘 다 `Fatal error: stack overflow`

즉 문제는 fib 전체가 커서 발생하는 것이 아니라, `LOCAL.GET`/`GLOBAL.GET` 같은 단일 `Step-read` 예제에서도 이미 발생한다.

### 3.3 helper 함수 자체 원인 여부 확인

`LOCAL.GET`/`GLOBAL.GET`이 쓰는 helper 함수가 직접 원인인지 분리했다.

실행:

```maude
red in WASM-FIB-BS : $local(fib-state(i32v(1)), 1) .
red in WASM-FIB-BS : $global(fib-state(i32v(1)), 1) .
```

결과:

- 둘 다 정상 종료

따라서 `$local/$global` helper 자체가 stack overflow의 직접 원인은 아니다.

### 3.4 schema rule 원인 여부 확인

초기 가설 중 하나는 baseline의 `Step/pure`, `Step/read` schema rule이 자기 재귀적 탐색을 유발한다는 것이었다.  
그래서 baseline translator에서 schema rule 생성 경로를 제거한 뒤 다시 확인했다.

결과:

- overflow 지속

즉 schema rule만의 문제는 아니다.

### 3.5 `ctxt-instrs` 과매칭 여부 확인

또 다른 가설은 `step-ctxt-instrs`가 empty focus까지 너무 넓게 잡으면서 탐색을 과도하게 유발한다는 것이었다.  
그래서 다음 guard를 추가했다.

```maude
... /\ STEP-CTXT-INSTRS2-INSTR =/= eps
```

결과:

- overflow 지속

즉 `ctxt-instrs` empty-focus 과매칭만의 문제도 아니다.

### 3.6 context rule 개별/전체 제거 실험

다음으로 context rule이 직접 원인인지 보기 위해 baseline translator에 스위치를 넣고, `step-ctxt-*` rule을 하나씩 또는 전부 제거한 variant를 생성했다.

실험한 경우:

- `ctxt-instrs`만 제거
- `ctxt-label`만 제거
- `ctxt-instrs`, `ctxt-label`, `ctxt-handler`, `ctxt-frame` 전부 제거

그리고 각 경우에 대해 다음을 다시 실행했다.

```maude
rew in WASM-FIB-BS : step(< fib-state(i32v(1)) | CTORLOCALGETA1(1) >) .
```

결과:

- 세 경우 모두 여전히 `Fatal error: stack overflow`

즉 context rule을 전부 꺼도 overflow가 남는다.  
따라서 원인은 heating/cooling 대체용 context rule 자체가 아니다.

### 3.7 `focused-step` 중간 relation 분리 실험

마지막으로, “모든 conditional rule을 `step` symbol에 직접 얹어서 생긴 문제인지”를 보기 위해 중간 relation을 하나 더 두는 실험을 했다.

추가한 구조:

```maude
op focused-step : ExecConf -> ExecConf .
rl [step-enter] : step(EC) => focused-step(EC) .
```

그리고 baseline direct conditional rule 전부를

- `step(<...>)`

가 아니라

- `focused-step(<...>)`

위에 생성되도록 바꾸었다.

그 뒤 다시 실행:

```maude
rew in WASM-FIB-BS : step(< fib-state(i32v(1)) | CTORLOCALGETA1(1) >) .
rewrite [10000] in WASM-FIB-BS : steps(fib-config(i32v(5))) .
```

결과:

- 여전히 둘 다 `Fatal error: stack overflow`

즉 문제는 단순히 “rule이 너무 많이 `step`에 직접 붙어 있어서” 생긴 얕은 수준의 문제도 아니다.

## 4. 실험 결과 요약

### 4.1 확인된 사실

1. baseline direct conditional encoding은 fib 전체뿐 아니라 단일 `LOCAL.GET`/`GLOBAL.GET`에서도 `stack overflow`가 난다.
2. `$local/$global` helper는 단독으로는 정상 종료하므로 직접 원인이 아니다.
3. `Step/pure`, `Step/read` schema rule을 제거해도 해결되지 않는다.
4. `step-ctxt-instrs`에 non-empty focus guard를 넣어도 해결되지 않는다.
5. `step-ctxt-*` context rule을 개별 제거하거나 전부 제거해도 해결되지 않는다.
6. `focused-step`이라는 중간 relation으로 한 번 분리해도 해결되지 않는다.

### 4.2 현재 가장 강한 결론

현재까지의 실험 기준으로 가장 강하게 말할 수 있는 결론은 다음과 같다.

- baseline stack overflow의 직접 원인은 helper 함수나 개별 조건식이 아니다.
- context rule만의 문제도 아니다.
- `step` symbol에 직접 rule을 얹은 것만의 얕은 문제도 아니다.
- 즉, **`-- Step:` rule들을 heating/cooling 없이 direct conditional rule로 직역한 baseline encoding 자체가 Maude proof search를 폭발시키는 것**으로 보인다.

## 5. 현재 문제점

현재 baseline은 다음 이유로 연구 기준선으로는 의미가 있지만, 실행 기준선으로는 아직 미완성이다.

- source `-- Step:` rule 5개를 모두 자동 생성하는 데는 성공
- manual override 없이 translator-generated rule만 사용하는 baseline harness도 구성
- 그러나 actual fib rewrite/model checking은 모두 `stack overflow`

즉 baseline은 “heating/cooling 없이 direct conditional rule 직역만으로는 Maude에서 proof search explosion이 발생한다”는 비교 실험 결과를 보여주는 데는 유효하지만, 실제 실행 가능한 reference semantics로는 아직 부족하다.

## 6. 향후 해결 방향

현재 가능한 해결 방향은 다음 두 가지로 생각하고 있다.

### 방향 A. baseline은 비교 기준선으로만 사용

- direct conditional baseline은 여기까지를 결과로 삼는다.
- 즉 “이 방식은 stack overflow가 난다”는 것을 baseline 결과로 보존한다.
- 실제 동작 가능한 translator는 heating/cooling 기반 `translator.ml`를 중심으로 발전시킨다.

이 방향의 장점:

- 교수님이 제안하신 baseline과 optimized translator의 차이를 명확히 보여줄 수 있음
- 현재 실험 결과 자체가 논문/보고서에 의미 있는 negative result가 됨

### 방향 B. baseline encoding을 더 제한적으로 다시 설계

- 완전한 direct conditional rule 직역 대신
- proof search를 통제할 수 있는 추가 장치를 두는 baseline 표현을 다시 설계한다.

예:

- 더 강한 focused relation 분리
- 특정 step family를 별도 relation으로 분리
- proof search를 줄이는 additional control layer 도입

이 방향의 장점:

- baseline도 실제로 fib가 동작하는 reference implementation이 될 수 있음

단점:

- 이미 “직역 baseline”의 단순성은 잃게 됨
- baseline도 결국 상당한 설계가 들어간 translator가 됨

## 7. 교수님께 드리고 싶은 질문

현재 실험 결과를 바탕으로 아래를 여쭙고 싶다.

1. 이번 baseline은 “direct conditional rule 직역은 Maude proof search explosion으로 잘 동작하지 않는다”는 비교 기준선으로 두고, 본 translator는 heating/cooling 기반으로 가는 것이 맞을지
2. 아니면 baseline도 반드시 실제 fib/model checking이 동작하는 수준까지 살려야 하는지
3. 만약 baseline도 살려야 한다면, direct conditional rule 직역 외에
   - step family 분리
   - focused relation 도입
   - 기타 proof-search control 장치
   같은 보조 설계를 baseline에 허용할 수 있는지

## 8. 교수님께 바로 말씀드릴 수 있는 짧은 결론

현재까지의 결론을 한 문장으로 줄이면 다음과 같다.

> `-- Step:` rule들을 heating/cooling 없이 direct conditional rule로 1:1 변환한 baseline을 만들었는데, fib 전체뿐 아니라 `LOCAL.GET` 같은 단일 `Step-read`도 stack overflow가 납니다. helper 함수, schema rule, context rule, `focused-step` 분리까지 확인했지만 해결되지 않았고, 현재는 baseline direct conditional encoding 자체가 Maude proof search를 폭발시키는 것으로 보입니다.
