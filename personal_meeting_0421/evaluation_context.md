# Evaluation Context on 2026-04-20

이 문서는 SpecTec의 evaluation context rule과 현재 `output.maude` / `wasm-exec.maude`의 대응 코드를 모은 것이다.

현재 구현 상태 요약:

- source context rule은 4개다.
  - `Step/ctxt-instrs`
  - `Step/ctxt-label`
  - `Step/ctxt-handler`
  - `Step/ctxt-frame`
- 현재 `output.maude`는 다음만 auto-generated heat/cool을 가진다.
  - `label`
  - `handler`
  - `frame`
- 현재 `instrs` context는 auto-generated되지 않는다.
- `wasm-exec.maude`에는 execution bootstrap / override 성격의 manual rule이 남아 있다.

## 1. Source Spectec Context Rules

출처: [wasm-3.0/4.3-execution.instructions.spectec](/Users/minsung/Dev/projects/Spec2Maude/wasm-3.0/4.3-execution.instructions.spectec:32)

```spectec
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

## 2. Current Auto-generated Context Rules in `output.maude`

### 2.1 Label

출처: [output.maude](/Users/minsung/Dev/projects/Spec2Maude/output.maude:7532)

```maude
crl [heat-step-ctxt-label] :
  step(< Z | CTORLABELLBRACERBRACEA3 ( N, Q, IS ) IS' >)
  => restore-label(step(< Z | IS >), N, Q, IS')
  if all-vals ( IS ) = false /\ is-trap ( IS ) = false /\ needs-label-ctxt ( IS ) = false .

rl [cool-step-ctxt-label] :
  restore-label(< Z' | IS >, N, Q, IS')
  => < Z' | CTORLABELLBRACERBRACEA3 ( N, Q, IS ) IS' > .

crl [cool-step-ctxt-label-control] :
  restore-label(step(< Z | IS >), N, Q, IS')
  => step(< Z | CTORLABELLBRACERBRACEA3 ( N, Q, IS ) IS' >)
  if needs-label-ctxt ( IS ) = true .
```

(변수: `Z` = 상태, `Z'` = 내부 스텝 후 상태, `N` = label arity,
 `Q` = label의 저장된 instr 시퀀스, `IS` = 내부 실행 시퀀스, `IS'` = label 뒤쪽 잔여)

### 2.2 Handler

출처: [output.maude](/Users/minsung/Dev/projects/Spec2Maude/output.maude:7543)

```maude
crl [heat-step-ctxt-handler] :
  step(< Z | CTORHANDLERLBRACERBRACEA3 ( N, CATCH, IS ) IS' >)
  => restore-handler(step(< Z | IS >), N, CATCH, IS')
  if all-vals ( IS ) = false /\ is-trap ( IS ) = false .

rl [cool-step-ctxt-handler] :
  restore-handler(< Z' | IS >, N, CATCH, IS')
  => < Z' | CTORHANDLERLBRACERBRACEA3 ( N, CATCH, IS ) IS' > .

crl [cool-step-ctxt-handler-control] :
  restore-handler(step(< Z | IS >), N, CATCH, IS')
  => step(< Z | CTORHANDLERLBRACERBRACEA3 ( N, CATCH, IS ) IS' >)
  if needs-label-ctxt ( IS ) = true .
```

(변수: `Z` = 상태, `Z'` = 내부 스텝 후 상태, `N` = handler arity,
 `CATCH` = catch 시퀀스, `IS` = 내부 실행 시퀀스, `IS'` = handler 뒤쪽 잔여)

### 2.3 Frame

출처: [output.maude](/Users/minsung/Dev/projects/Spec2Maude/output.maude:7554)

```maude
crl [heat-step-ctxt-frame] :
  step(< CTORSEMICOLONA2 ( S, F ) | CTORFRAMELBRACERBRACEA3 ( N, F', IS ) IS' >)
  => restore-frame(step(< CTORSEMICOLONA2 ( S, F' ) | IS >), N, F, IS')
  if all-vals ( IS ) = false /\ is-trap ( IS ) = false .

rl [cool-step-ctxt-frame] :
  restore-frame(< Z' | IS >, N, F, IS')
  => < CTORSEMICOLONA2 ( $store ( Z' ), F ) | CTORFRAMELBRACERBRACEA3 ( N, $frame ( Z' ), IS ) IS' > .

crl [cool-step-ctxt-frame-control] :
  restore-frame(step(< CTORSEMICOLONA2 ( S, F' ) | IS >), N, F, IS')
  => step(< CTORSEMICOLONA2 ( S, F ) | CTORFRAMELBRACERBRACEA3 ( N, F', IS ) IS' >)
  if needs-label-ctxt ( IS ) = true .
```

(변수: `S` = store, `F` = 외부 frame, `F'` = 내부 frame, `Z'` = 내부 스텝 후 상태,
 `N` = frame arity, `IS` = 내부 실행 시퀀스, `IS'` = frame 뒤쪽 잔여)

## 3. `instrs` Context: Current Status

### 3.1 Source rule exists

`Step/ctxt-instrs`는 source에 존재한다.

```spectec
rule Step/ctxt-instrs:
  z; val* instr* instr_1*  ~>  z'; val* instr'* instr_1*
  -- Step: z; instr* ~> z'; instr'*
  -- if val* =/= eps \/ instr_1* =/= eps
```

### 3.2 But current `output.maude` does not auto-generate generic `instrs` heat/cool

현재 `output.maude`에는 `heat-step-ctxt-instrs` / `cool-step-ctxt-instrs`가 없다.

이 상태는 의도적이다.

- 이전 generic `instrs` heat/cool은 fib 실행에서 `restore-instrs(step(...))` deadlock/회귀를 만들었다.
- 그래서 현재 translator는 `instrs` context auto-generation을 비활성화한 상태다.

### 3.3 Current manual support in `wasm-exec.maude`

출처: [wasm-exec.maude](/Users/minsung/Dev/projects/Spec2Maude/wasm-exec.maude:69)

```maude
crl [step-local-set-manual] :
  step(< CTORSEMICOLONA2(ST-ZS, ST-ZF) | ST-VALS ST-VAL CTORLOCALSETA1(ST-X) ST-IS >)
  =>
  < CTORSEMICOLONA2(ST-ZS, ST-ZF [. 'LOCALS <- value('LOCALS, ST-ZF) [ST-X <- ST-VAL]]) | ST-VALS ST-IS >
  if all-vals(ST-VALS) = true /\ is-val(ST-VAL) = true .

crl [step-local-tee-manual] :
  step(< CTORSEMICOLONA2(ST-ZS, ST-ZF) | ST-VALS ST-VAL CTORLOCALTEEA1(ST-X) ST-IS >)
  =>
  < CTORSEMICOLONA2(ST-ZS, ST-ZF [. 'LOCALS <- value('LOCALS, ST-ZF) [ST-X <- ST-VAL]]) | ST-VALS ST-VAL ST-IS >
  if all-vals(ST-VALS) = true /\ is-val(ST-VAL) = true .

crl [step-global-set-manual] :
  step(< ST-Z | ST-VALS ST-VAL CTORGLOBALSETA1(ST-X) ST-IS >)
  =>
  < $with-global(ST-Z, ST-X, ST-VAL) | ST-VALS ST-IS >
  if all-vals(ST-VALS) = true /\ is-val(ST-VAL) = true .

crl [step-read-local-get-manual] :
  step(< ST-Z | ST-VALS CTORLOCALGETA1(ST-X) ST-IS >)
  =>
  < ST-Z | ST-VALS ST-VAL ST-IS >
  if all-vals(ST-VALS) = true /\ ST-VAL := $local(ST-Z, ST-X) .

crl [step-read-global-get-manual] :
  step(< ST-Z | ST-VALS CTORGLOBALGETA1(ST-X) ST-IS >)
  =>
  < ST-Z | ST-VALS ST-VAL ST-IS >
  if all-vals(ST-VALS) = true /\ ST-VAL := value('VALUE, $global(ST-Z, ST-X)) .

crl [step-read-call-manual] :
  step(< ST-Z | ST-VALS CTORCALLA1(ST-X) ST-IS >)
  =>
  < ST-Z | ST-VALS CTORREFFUNCADDRA1(ST-A) CTORCALLREFA1(ST-TY) ST-IS >
  if all-vals(ST-VALS) = true /\ ST-A := index(value('FUNCS, $moduleinst(ST-Z)), ST-X)
  /\ ST-TY := value('TYPE, index($funcinst(ST-Z), ST-A)) .

crl [step-read-block-manual] :
  step(< ST-Z | ST-VALS CTORBLOCKA2(ST-BT, ST-BODY) ST-IS >)
  =>
  < ST-Z | CTORLABELLBRACERBRACEA3(ST-LEN, eps, ST-VALS ST-BODY) ST-IS >
  if all-vals(ST-VALS) = true
  /\ CTORARROWA3(ST-TQ, eps, ST-TR) := $blocktype(ST-Z, ST-BT)
  /\ ST-LEN := len(ST-TR) .

crl [step-read-loop-manual] :
  step(< ST-Z | ST-VALS CTORLOOPA2(ST-BT, ST-BODY) ST-IS >)
  =>
  < ST-Z | CTORLABELLBRACERBRACEA3(ST-LEN, CTORLOOPA2(ST-BT, ST-BODY), ST-VALS ST-BODY) ST-IS >
  if all-vals(ST-VALS) = true
  /\ CTORARROWA3(ST-TQ, eps, ST-TR) := $blocktype(ST-Z, ST-BT)
  /\ ST-LEN := len(ST-TR) .

crl [step-call-ref] :
  step(< ST-Z | ST-VALS CTORREFFUNCADDRA1(ST-A) CTORCALLREFA1(ST-YY) ST-IS >)
  =>
  < ST-Z | ST-VALS CTORFRAMELBRACERBRACEA3(ST-LEN, ST-FI,
           CTORLABELLBRACERBRACEA3(ST-LEN, eps, ST-VALS ST-BODY)) ST-IS >
```

## 4. Practical Conclusion

현재 evaluation context는 “전부 heat/cool”이라고 말하면 안 된다.

정확히는:

- `label`: auto-generated heat/cool
- `handler`: auto-generated heat/cool
- `frame`: auto-generated heat/cool
- `instrs`: 현재 auto-generated 아님
- 일부 execution bootstrap / override는 `wasm-exec.maude` manual rule에 남아 있음
