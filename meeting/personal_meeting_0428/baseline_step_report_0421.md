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

정확히 말하면 source에서 `-- Step:` premise가 붙어 있는 rule은 총 5개였다.

- `Steps/trans`
- `Step/ctxt-instrs`
- `Step/ctxt-label`
- `Step/ctxt-handler`
- `Step/ctxt-frame`

다만 이번 비교에서 봐야 하는 structural/context rule 묶음은 위 5개에 다음 3개 schema/refl rule까지 포함한 총 8개다.

- `Step/pure`
- `Step/read`
- `Steps/refl`

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

## 5. 선배 수동 코드와의 차이

### 5.1 왜 선배 코드는 overflow가 안 나는가

선배 코드(`Spec2Maude_JHS/`)는 SpecTec rule을 1:1로 직역한 baseline이 아니라, Maude에서 실행이 잘 되도록 손으로 재구성한 interpreter-style semantics에 가깝다.

대표적으로 `LOCAL.GET`은 다음처럼 직접 redex를 잡아 바로 실행한다.

```maude
crl [localget] : STATE ; (VALS ((LOCAL.GET X_IDX_LOCALGET)) INSTRS)
  => STATE ; (VALS ((VAL)) INSTRS)
  if VAL := $local(STATE, X_IDX_LOCALGET) .
```

이 rule은 조건 안에서 다시 `step(...) => ...`를 증명하지 않는다. 현재 instruction prefix가 `LOCAL.GET`이면 `$local` lookup을 한 번 하고 끝난다.

반면 baseline의 context rule은 다음처럼 조건 안에서 다시 `focused-step(...) => ...`를 요구한다.

```maude
crl [step-ctxt-instrs] :
  focused-step(< Z | VALS VAL INSTR INSTR1 IS >)
  => < ZQ | VALS VAL INSTRQ INSTR1 IS >
  if all-vals(VALS) = true
  /\ all-vals(VAL) = true
  /\ focused-step(< Z | INSTR >) => < ZQ | INSTRQ >
  /\ ...
```

Maude는 이 rewrite condition을 만족시키기 위해 `focused-step`에 걸린 모든 rule을 다시 탐색한다. baseline에는 fib에 필요한 rule뿐 아니라 memory/table/GC/array/SIMD/exception rule까지 같이 올라와 있고, instruction sequence는 associative list라서 가능한 분해도 많다. 그래서 `LOCAL.GET` 하나를 실행하려고 해도 조건부 rewrite 증명 과정에서 큰 proof search가 발생한다.

즉 현재 현상은 엄밀히는 model checking state-space explosion이라기보다, 한 step을 만들기 전의 **conditional rewrite proof search explosion**에 가깝다.

### 5.2 왜 baseline을 선배 코드처럼 작성하면 안 되는가

선배 코드 방식은 실행에는 좋지만, 이번 연구의 baseline 목적과는 다르다.

- 선배 코드는 fib 등 현재 필요한 fragment를 잘 돌리기 위해 control structure를 손으로 설계했다.
- `context: ... :: stage: ...`, `endlabel`, `endframe` 같은 실행 제어 장치를 도입해 SpecTec의 원래 `Step/ctxt-*` rule 모양을 바꾼다.
- 따라서 source SpecTec rule과 generated Maude rule 사이의 직접 대응이 약해진다.
- 이 방식으로 baseline을 만들면 “SpecTec rule을 direct conditional rule로 1:1 변환했을 때 correct하지만 느린 기준선”이라는 역할을 잃는다.

즉 선배 코드 스타일은 나중에 optimized translator 또는 harness 설계의 참고가 될 수는 있지만, baseline 그 자체가 되면 안 된다. baseline은 느리거나 실패하더라도 SpecTec rule 구조를 최대한 보존해야 한다. 그래야 이후 heating/cooling 기반 translator가 의미를 보존하는 최적화인지 비교할 수 있다.

## 6. Structural/context rule 비교

이번 baseline에서 본질적으로 비교해야 하는 structural/context rule은 총 8개다.

- `Step/pure`
- `Step/read`
- `Steps/refl`
- `Steps/trans`
- `Step/ctxt-instrs`
- `Step/ctxt-label`
- `Step/ctxt-handler`
- `Step/ctxt-frame`

이 중 source에서 `-- Step:` premise가 실제로 붙은 것은 `Steps/trans`와 `Step/ctxt-*` 네 개, 총 5개다. `Step/pure`, `Step/read`는 각각 `Step_pure`, `Step_read` schema premise를 갖고, `Steps/refl`은 premise가 없다.

### 6.1 SpecTec source

```spectec
rule Step/pure:
  z; instr*  ~>  z; instr'*
  -- Step_pure: instr* ~> instr'*

rule Step/read:
  z; instr*  ~>  z; instr'*
  -- Step_read: z; instr* ~> instr'*

rule Steps/refl:
  z; instr* ~>* z; instr*

rule Steps/trans:
  z; instr*  ~>*  z''; instr''*
  -- Step: z; instr*  ~>  z'; instr'*
  -- Steps: z'; instr'*  ~>*  z''; instr''*

rule Step/ctxt-instrs:
  z; val* instr* instr_1*  ~>  z'; val* instr'* instr_1*
  -- Step: z; instr* ~> z'; instr'*
  -- if val* =/= eps \/ instr_1* =/= eps

rule Step/ctxt-label:
  z; (LABEL_ n `{instr_0*} instr*)  ~>  z'; (LABEL_ n `{instr_0*} instr'*)
  -- Step: z; instr* ~> z'; instr'*

rule Step/ctxt-handler:
  z; (HANDLER_ n `{catch*} instr*) ~> z'; (HANDLER_ n `{catch*} instr'*)
  -- Step: z; instr* ~> z'; instr'*

rule Step/ctxt-frame:
  s; f; (FRAME_ n `{f'} instr*)  ~>  s'; f; (FRAME_ n `{f''} instr'*)
  -- Step: s; f'; instr* ~> s'; f''; instr'*
```

### 6.2 `output_bs.maude` baseline direct conditional form

Baseline은 context를 heating/cooling으로 바꾸지 않고, source premise를 condition의 rewrite condition으로 그대로 둔다. 현재는 direct `step(...)` 대신 `focused-step(...)`에 올려져 있지만, proof-search 구조는 동일하다.
아래 코드는 실제 `output_bs.maude`의 구조를 보존하되, 발표/검토용 가독성을 위해 generated 변수명만 짧게 줄인 것이다.

```maude
crl [steps-refl] :
  Steps(CTORSEMICOLONA2(Z, INSTR), CTORSEMICOLONA2(Z, INSTR))
  => valid
  if Z : State /\ (INSTR hasType (list(instr))) : WellTyped .

crl [steps-trans] :
  Steps(CTORSEMICOLONA2(Z, INSTR), CTORSEMICOLONA2(ZQQ, INSTRQQ))
  => valid
  if step(< Z | INSTR >) => < ZQ | INSTRQ >
  /\ Steps(CTORSEMICOLONA2(ZQ, INSTRQ), CTORSEMICOLONA2(ZQQ, INSTRQQ)) => valid
  /\ Z : State /\ (INSTR hasType (list(instr))) : WellTyped
  /\ ZQQ : State /\ (INSTRQQ hasType (list(instr))) : WellTyped .

crl [step-ctxt-instrs] :
  focused-step(< Z | VALS VAL INSTR INSTR1 IS >)
  => < ZQ | VALS VAL INSTRQ INSTR1 IS >
  if all-vals(VALS) = true
  /\ all-vals(VAL) = true
  /\ focused-step(< Z | INSTR >) => < ZQ | INSTRQ >
  /\ ((VAL =/= eps) or (INSTR1 =/= eps)) = true
  /\ Z : State
  /\ INSTR =/= eps .

crl [step-ctxt-label] :
  focused-step(< Z | VALS CTORLABELLBRACERBRACEA3(N, INSTR0, INSTR) IS >)
  => < ZQ | VALS CTORLABELLBRACERBRACEA3(N, INSTR0, INSTRQ) IS >
  if all-vals(VALS) = true
  /\ focused-step(< Z | INSTR >) => < ZQ | INSTRQ >
  /\ Z : State /\ N : N .

crl [step-ctxt-handler] :
  focused-step(< Z | VALS CTORHANDLERLBRACERBRACEA3(N, CATCH, INSTR) IS >)
  => < ZQ | VALS CTORHANDLERLBRACERBRACEA3(N, CATCH, INSTRQ) IS >
  if all-vals(VALS) = true
  /\ focused-step(< Z | INSTR >) => < ZQ | INSTRQ >
  /\ Z : State /\ N : N .

crl [step-ctxt-frame] :
  focused-step(< CTORSEMICOLONA2(S, F) | VALS CTORFRAMELBRACERBRACEA3(N, FQ, INSTR) IS >)
  => < CTORSEMICOLONA2(SQ, F) | VALS CTORFRAMELBRACERBRACEA3(N, FQQ, INSTRQ) IS >
  if all-vals(VALS) = true
  /\ focused-step(< CTORSEMICOLONA2(S, FQ) | INSTR >) => < CTORSEMICOLONA2(SQ, FQQ) | INSTRQ >
  /\ S : Store /\ F : Frame /\ N : N /\ FQ : Frame .
```

`Step/pure`와 `Step/read` schema는 baseline에서 별도의 wrapper rule 하나로 남기기보다, concrete `Step_pure/*`, `Step_read/*` rule들이 `focused-step(< Z | ... >)` 형태로 직접 생성된다. 예를 들면 `step-pure-nop`, `step-read-local-get` 같은 label rule들이다.

### 6.3 선배 수동 Maude 코드

선배 코드는 위 source rule을 그대로 condition으로 옮기지 않는다. 대신 frame/label context를 별도 context stack과 `stage`로 분해한다.

```maude
eq (context: LC / FC ) ::
  (stage: ((STORE ; FRAME) ;
  INSTRS' (FRAME- N {FRAME'} INSTRS END) INSTRS'')) =
  (context: LC / (frame(FRAME, INSTRS' [] INSTRS'', N) # FC )) ::
  (stage: ((STORE ; FRAME') ; (INSTRS endframe))) .

eq (context: LC / (frame(FRAME, INSTRS' [] INSTRS'', N) # FC )) ::
  (stage: ((STORE ; FRAME') ; (VALS endframe))) =
  (context: LC / FC) ::
  (stage: ((STORE ; FRAME) ; (INSTRS' VALS INSTRS''))) .

eq (context: LC / FC ) ::
  (stage: ((STORE ; FRAME) ;
  INSTRS' (LABEL- N {INSTRS_STORED} INSTRS END) INSTRS'')) =
  (context: (label(INSTRS_STORED, INSTRS' [] INSTRS'', N) @ LC) / FC ) ::
  (stage: ((STORE ; FRAME) ; (INSTRS endlabel))) .

eq (context: (label(INSTRS_STORED, INSTRS' [] INSTRS'', N) @ LC) / FC ) ::
  (stage: ((STORE ; FRAME) ; (VALS endlabel))) =
  (context: LC / FC) ::
  (stage: ((STORE ; FRAME) ; (INSTRS' VALS INSTRS''))) .
```

그리고 concrete instruction rule은 직접 redex를 잡는다.

```maude
crl [localget] : STATE ; (VALS ((LOCAL.GET X_IDX_LOCALGET)) INSTRS)
  => STATE ; (VALS ((VAL)) INSTRS)
  if VAL := $local(STATE, X_IDX_LOCALGET) .

rl [localset] : (STORE ; FRAME) ; (VALS (VAL_LOCALSET (LOCAL.SET X_IDX_LOCALSET)) INSTRS)
  => (STORE ; (FRAME[. 'LOCALS' <- (value('LOCALS', FRAME)[X_IDX_LOCALSET <- VAL_LOCALSET])])) ;
     (VALS INSTRS) .
```

따라서 선배 코드에는 baseline의 `Step/ctxt-*`에 해당하는 direct conditional rewrite premise가 없다. context 처리는 equation으로 stage를 바꾸는 방식이고, 실제 instruction rule은 좁은 redex에 바로 적용된다.

### 6.4 `output.maude` 현재 optimized/heating-cooling form

현재 `translator.ml` 경로는 `Step/ctxt-label`, `Step/ctxt-handler`, `Step/ctxt-frame`을 direct conditional rule 대신 heat/cool 세트로 생성한다. `Step/ctxt-instrs`는 과거 회귀 때문에 현재 생성하지 않는다.
아래 코드도 실제 `output.maude`의 구조를 보존하되, generated 변수명만 짧게 줄인 것이다.

```maude
crl [heat-step-ctxt-label] :
  step(< Z | CTORLABELLBRACERBRACEA3(N, INSTR0, INNER) REST >)
  => restore-label(step(< Z | INNER >), N, INSTR0, REST)
  if all-vals(INNER) = false
  /\ is-trap(INNER) = false
  /\ needs-label-ctxt(INNER) = false .

rl [cool-step-ctxt-label] :
  restore-label(< ZN | IS >, N, INSTR0, REST)
  => < ZN | CTORLABELLBRACERBRACEA3(N, INSTR0, IS) REST > .

crl [cool-step-ctxt-label-control] :
  restore-label(step(< Z | INNER >), N, INSTR0, REST)
  => step(< Z | CTORLABELLBRACERBRACEA3(N, INSTR0, INNER) REST >)
  if needs-label-ctxt(INNER) = true .
```

Handler와 frame도 같은 패턴이다.

```maude
crl [heat-step-ctxt-handler] :
  step(< Z | CTORHANDLERLBRACERBRACEA3(N, CATCH, INNER) REST >)
  => restore-handler(step(< Z | INNER >), N, CATCH, REST)
  if all-vals(INNER) = false /\ is-trap(INNER) = false .

rl [cool-step-ctxt-handler] :
  restore-handler(< ZN | IS >, N, CATCH, REST)
  => < ZN | CTORHANDLERLBRACERBRACEA3(N, CATCH, IS) REST > .

crl [heat-step-ctxt-frame] :
  step(< CTORSEMICOLONA2(S, F) | CTORFRAMELBRACERBRACEA3(N, FQ, INNER) REST >)
  => restore-frame(step(< CTORSEMICOLONA2(S, FQ) | INNER >), N, F, REST)
  if all-vals(INNER) = false /\ is-trap(INNER) = false .

rl [cool-step-ctxt-frame] :
  restore-frame(< ZN | IS >, N, FOUTER, REST)
  => < CTORSEMICOLONA2($store(ZN), FOUTER) | CTORFRAMELBRACERBRACEA3(N, $frame(ZN), IS) REST > .
```

`Steps/refl`과 `Steps/trans`는 current와 baseline 모두 relation judgement로 남아 있다.

```maude
crl [steps-refl] :
  Steps(CTORSEMICOLONA2(Z, INSTR), CTORSEMICOLONA2(Z, INSTR))
  => valid
  if Z : State /\ (INSTR hasType (list(instr))) : WellTyped .

crl [steps-trans] :
  Steps(CTORSEMICOLONA2(Z, INSTR), CTORSEMICOLONA2(ZQQ, INSTRQQ))
  => valid
  if step(< Z | INSTR >) => < ZQ | INSTRQ >
  /\ Steps(CTORSEMICOLONA2(ZQ, INSTRQ), CTORSEMICOLONA2(ZQQ, INSTRQQ)) => valid
  /\ Z : State /\ (INSTR hasType (list(instr))) : WellTyped
  /\ ZQQ : State /\ (INSTRQQ hasType (list(instr))) : WellTyped .
```

정리하면 baseline에서 가장 크게 바뀐 부분은 `Step/ctxt-*`의 처리 방식이다. current는 label/handler/frame을 heat/cool로 우회하고 `ctxt-instrs`는 꺼 둔다. baseline은 `ctxt-instrs`까지 포함해 source의 conditional premise를 direct `crl`로 살린다. 이 directness 때문에 baseline이 더 1:1 isomorphic하지만, Maude의 conditional rewrite search가 훨씬 커진다.

## 7. 현재 문제점

현재 baseline은 다음 이유로 연구 기준선으로는 의미가 있지만, 실행 기준선으로는 아직 미완성이다.

- source `-- Step:` rule 5개를 모두 자동 생성하는 데는 성공
- manual override 없이 translator-generated rule만 사용하는 baseline harness도 구성
- 그러나 actual fib rewrite/model checking은 모두 `stack overflow`

즉 baseline은 “heating/cooling 없이 direct conditional rule 직역만으로는 Maude에서 proof search explosion이 발생한다”는 비교 실험 결과를 보여주는 데는 유효하지만, 실제 실행 가능한 reference semantics로는 아직 부족하다.

## 8. 향후 해결 방향

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

## 9. 교수님께 드리고 싶은 질문

현재 실험 결과를 바탕으로 아래를 여쭙고 싶다.

1. 이번 baseline은 “direct conditional rule 직역은 Maude proof search explosion으로 잘 동작하지 않는다”는 비교 기준선으로 두고, 본 translator는 heating/cooling 기반으로 가는 것이 맞을지
2. 아니면 baseline도 반드시 실제 fib/model checking이 동작하는 수준까지 살려야 하는지
3. 만약 baseline도 살려야 한다면, direct conditional rule 직역 외에
   - step family 분리
   - focused relation 도입
   - 기타 proof-search control 장치
   같은 보조 설계를 baseline에 허용할 수 있는지

## 10. 교수님께 바로 말씀드릴 수 있는 짧은 결론

현재까지의 결론을 한 문장으로 줄이면 다음과 같다.

> `-- Step:` rule들을 heating/cooling 없이 direct conditional rule로 1:1 변환한 baseline을 만들었는데, fib 전체뿐 아니라 `LOCAL.GET` 같은 단일 `Step-read`도 stack overflow가 납니다. helper 함수, schema rule, context rule, `focused-step` 분리까지 확인했지만 해결되지 않았고, 현재는 baseline direct conditional encoding 자체가 Maude proof search를 폭발시키는 것으로 보입니다.
