# Baseline stack overflow 원인 가설 및 수정 방향

## 1. 한 줄 요약

현재 baseline에서 발생하는 stack overflow는 `crl` 자체가 본질적으로 불가능해서라기보다, `WasmTerminals`가 `eps`를 identity로 갖는 associative sequence인데, 이 sequence를 conditional rule의 좌항과 조건에서 너무 자유롭게 분해하기 때문에 발생하는 것으로 보인다.

즉 교수님께서 말씀하신 `nil` 문제와 같은 종류의 문제가 현재 baseline에서도 발생하고 있을 가능성이 높다.

수정 방향은 단순히 조건에 `INSTR =/= eps`를 추가하는 것이 아니라, Maude rule의 좌항 패턴 자체에서 recursive focus가 empty sequence로 match되지 못하도록 바꾸는 것이다.

---

## 2. 현재 실험에서 확인한 증상

baseline은 교수님 말씀대로 `-- Step:` premise가 있는 rule을 heating/cooling rule이 아니라 direct conditional rule로 변환한 것이다.

예를 들어 SpecTec rule에 다음과 같은 premise가 있으면,

```spectec
-- Step: z; instr* ~> z'; instr'*
```

baseline에서는 이를 Maude 조건부 rewrite premise로 바꾼다.

```maude
step(< Z | INSTR >) => < ZQ | INSTRQ >
```

그런데 baseline output으로 fibonacci model checking을 실행하면 stack overflow가 난다.

더 중요한 점은, fibonacci 전체 실행이 아니라 아주 작은 한 step에서도 stack overflow가 난다는 것이다.

실험:

```maude
rew [1] in WASM-FIB-BS :
  step(< fib-state(i32v(1)) | CTORLOCALGETA1(1) >) .
```

결과:

```text
Fatal error: stack overflow
```

따라서 문제는 `steps(...)`가 너무 오래 반복되어서 생기는 것이 아니다.

`step(...)` 하나를 적용하기 위해 Maude가 conditional rule을 찾고 조건을 증명하는 과정에서 이미 stack overflow가 발생한다.

반면 `local.get`이 사용하는 helper 함수 자체는 종료된다.

실험:

```maude
red in WASM-FIB-BS :
  $local(fib-state(i32v(1)), 1) .
```

결과:

```maude
CTORCONSTA2(CTORI32A0, 0)
```

따라서 `$local` helper 함수가 직접 stack overflow를 일으키는 것은 아니다.

현재 의심되는 지점은 `step` rule matching과 conditional rewrite premise 탐색이다.

---

## 3. 교수님께서 말씀하신 nil 문제

교수님께서 설명하신 예시는 다음과 같다.

```maude
var cf cf' : conf .

f(nil) : nil .
f(cf cf') : f(cf) f(cf') .
```

의도는 다음과 같다.

```maude
f(1 2 3 4)
```

가

```maude
f(1) f(2) f(3) f(4)
```

처럼 쪼개지는 것이다.

하지만 `nil`이 sequence의 identity이면 Maude는 다음과 같은 match도 생각할 수 있다.

```maude
cf  = nil
cf' = 1 2 3 4
```

그러면

```maude
f(1 2 3 4)
```

를 줄이는 과정에서

```maude
f(nil) f(1 2 3 4)
```

같은 형태가 생길 수 있다.

여기서 두 번째 항 `f(1 2 3 4)`는 원래 문제와 크기가 줄어들지 않았다.

즉 recursive call이 progress하지 않는다.

이런 식으로 empty sequence가 분해 결과에 끼어들면, 사람이 보기에는 당연히 줄어들어야 할 계산이 Maude 내부에서는 progress 없는 recursive search로 이어질 수 있다.

---

## 4. 현재 baseline이 교수님 예시와 같은 구조인 이유

우리 Maude 코드에서도 instruction sequence는 다음과 같이 정의되어 있다.

파일: `dsl/pretype.maude`

```maude
sort WasmTerminals .
subsort WasmTerminal < WasmTerminals .

op eps : -> WasmTerminals .
op _ _ : WasmTerminals WasmTerminals -> WasmTerminals [ctor assoc id: eps] .
```

여기서 중요한 부분은 다음이다.

```maude
[ctor assoc id: eps]
```

즉 `WasmTerminals`는 associative sequence이고, `eps`가 identity이다.

그래서 Maude는 sequence를 match할 때 `eps`를 중간에 넣는 분해도 고려할 수 있다.

baseline에서 특히 문제가 되는 rule은 `step-ctxt-instrs`이다.

현재 baseline output:

```maude
crl [step-ctxt-instrs] :
  step(< Z | VAL INSTR INSTR1 >)
  =>
  < ZQ | VAL INSTRQ INSTR1 >
  if all-vals ( VAL ) = true
  /\ step(< Z | INSTR >) => < ZQ | INSTRQ >
  /\ ( ( VAL =/= eps ) or ( INSTR1 =/= eps ) ) = true
  /\ Z : State
  /\ ZQ : State
  /\ INSTR =/= eps .
```

이 rule은 SpecTec의 다음 rule을 direct conditional rule로 옮긴 것이다.

```spectec
rule Step/ctxt-instrs:
  z; val* instr* instr_1*  ~>  z'; val* instr'* instr_1*
  -- Step: z; instr* ~> z'; instr'*
  -- if val* =/= eps \/ instr_1* =/= eps
```

SpecTec 의미 자체는 다음과 같다.

- 전체 instruction list 안에 어떤 부분 `instr*`가 있다.
- 그 부분이 한 step 움직여서 `instr'*`가 된다.
- 그러면 전체 list에서도 같은 위치의 부분만 `instr'*`로 바뀐다.

즉 evaluation context rule이다.

문제는 Maude에서 다음 패턴이 매우 넓게 match된다는 점이다.

```maude
VAL INSTR INSTR1
```

`VAL`, `INSTR`, `INSTR1`이 모두 `WasmTerminals`이면, 하나의 instruction list를 여러 방식으로 나눌 수 있다.

예를 들어 instruction list가 하나뿐인 경우를 생각하자.

```maude
CTORLOCALGETA1(1)
```

Maude는 이 하나짜리 list를 다음과 같이 분해할 수 있다.

```text
VAL = eps,               INSTR = CTORLOCALGETA1(1), INSTR1 = eps
VAL = eps,               INSTR = eps,               INSTR1 = CTORLOCALGETA1(1)
VAL = CTORLOCALGETA1(1), INSTR = eps,               INSTR1 = eps
...
```

사람이 보기에는 첫 번째 split만 의미 있어 보이지만, Maude의 associative identity matching에서는 다른 split 후보들도 생길 수 있다.

그 다음 Maude는 조건을 증명해야 한다.

```maude
step(< Z | INSTR >) => < ZQ | INSTRQ >
```

그런데 `INSTR`가 `eps`이거나, 원래 sequence와 충분히 줄어들지 않은 형태로 잡히면, 다시 `step(...)`을 증명하는 과정에서 같은 종류의 rule matching이 반복된다.

이 구조가 교수님께서 말씀하신

```maude
f(nil) f(1 2 3 4)
```

문제와 같다.

---

## 5. 왜 `INSTR =/= eps` guard만으로는 부족한가?

현재 baseline에는 이미 다음 조건이 들어가 있다.

```maude
INSTR =/= eps
```

처음에는 이 조건이 있으면 empty focus를 막을 수 있을 것처럼 보인다.

하지만 이 조건은 rule 좌항에서 match를 막는 것이 아니라, match가 된 뒤 조건에서 검사된다.

즉 Maude의 처리 순서를 단순화하면 다음과 같다.

1. 먼저 좌항 `step(< Z | VAL INSTR INSTR1 >)`에 대해 가능한 match를 찾는다.
2. 이때 `assoc id: eps` 때문에 `eps`를 포함한 여러 split 후보가 생긴다.
3. 각 후보에 대해 조건을 확인한다.
4. 조건 안에 다시 `step(< Z | INSTR >) => ...`가 있으므로, Maude는 또 다른 rewrite search를 시작한다.

따라서 `INSTR =/= eps`는 일부 후보를 나중에 탈락시킬 수는 있지만, 애초에 `eps`를 포함한 split 후보가 생기는 것 자체를 막지는 못한다.

이것이 현재 guard를 추가했는데도 stack overflow가 남는 이유로 보인다.

핵심은 다음이다.

```text
조건에서 empty를 거르는 것과,
좌항 패턴에서 empty가 match될 수 없게 만드는 것은 다르다.
```

현재 baseline은 전자이고, 필요한 수정은 후자이다.

---

## 6. 수정 방향: recursive focus를 non-empty pattern으로 만들기

수정의 목표는 `step` premise의 대상이 되는 focus instruction sequence가 empty로 잡히지 않도록 하는 것이다.

현재 방식:

```maude
step(< Z | VAL INSTR INSTR1 >)
```

여기서 `INSTR`는 `WasmTerminals`이다.

`WasmTerminals`는 `eps`가 될 수 있으므로, `INSTR`도 empty가 될 수 있다.

수정 방향:

```maude
var W : WasmTerminal .
var REST : WasmTerminals .
```

를 사용해서 recursive focus를 다음처럼 표현한다.

```maude
W REST
```

그러면 `W`는 `WasmTerminal`이므로 `eps`가 될 수 없다.

즉 `W REST`는 최소한 하나의 instruction을 포함하는 non-empty sequence가 된다.

수정된 rule의 형태는 다음과 같다.

```maude
crl [step-ctxt-instrs] :
  step(< Z | VAL W REST INSTR1 >)
  =>
  < ZQ | VAL INSTRQ INSTR1 >
  if all-vals ( VAL ) = true
  /\ step(< Z | W REST >) => < ZQ | INSTRQ >
  /\ ( ( VAL =/= eps ) or ( INSTR1 =/= eps ) ) = true
  /\ Z : State
  /\ ZQ : State .
```

여기서 한 가지 더 중요하다.

context rule은 prefix나 suffix가 있는 경우에만 적용되어야 한다.

즉 다음 조건이 recursive `step` premise보다 먼저 검사되어야 한다.

```maude
( ( VAL =/= eps ) or ( INSTR1 =/= eps ) ) = true
```

만약 조건 순서가 다음처럼 되어 있으면 문제가 남는다.

```maude
if all-vals ( VAL ) = true
/\ step(< Z | W REST >) => < ZQ | INSTRQ >
/\ ( ( VAL =/= eps ) or ( INSTR1 =/= eps ) ) = true
```

singleton instruction의 경우 `VAL = eps`, `INSTR1 = eps`이므로 context rule은 실패해야 한다.

하지만 Maude는 조건을 왼쪽부터 확인하므로, 위 순서에서는 context guard가 실패하기 전에 먼저 recursive `step(< Z | W REST >)`를 증명하려고 한다.

그래서 실제 수정에서는 조건 순서도 다음처럼 바꿔야 한다.

```maude
if all-vals ( VAL ) = true
/\ ( ( VAL =/= eps ) or ( INSTR1 =/= eps ) ) = true
/\ Z : State
/\ ZQ : State
/\ step(< Z | W REST >) => < ZQ | INSTRQ >
```

정리하면 수정은 두 부분이다.

1. recursive focus를 `INSTR` 하나가 아니라 `W REST`로 만들어 non-empty를 보장한다.
2. context 여부를 확인하는 guard를 recursive `step` premise보다 앞에 둔다.

이렇게 바꾸면 recursive premise가 다음처럼 바뀐다.

기존:

```maude
step(< Z | INSTR >) => < ZQ | INSTRQ >
```

수정 후:

```maude
step(< Z | W REST >) => < ZQ | INSTRQ >
```

여기서 `W REST`는 empty가 될 수 없다.

따라서 교수님께서 말씀하신 `nil` split 문제를 조건이 아니라 pattern 수준에서 막을 수 있다.

---

## 7. 이 수정이 SpecTec과 1:1 isomorphic한가?

완전히 문자를 그대로 옮긴 것은 아니다.

SpecTec에는 다음처럼 쓰여 있다.

```spectec
instr*
```

이것을 Maude에서 그대로 `INSTR : WasmTerminals` 하나로 옮기면 가장 표면적으로는 1:1에 가까워 보인다.

하지만 SpecTec rule의 premise는 다음이다.

```spectec
-- Step: z; instr* ~> z'; instr'*
```

여기서 `instr*`는 실제로 한 step을 수행할 수 있는 instruction sequence여야 한다.

empty instruction sequence는 한 step을 수행할 수 없다.

즉 의미적으로 recursive focus는 non-empty여야 한다.

따라서 Maude에서 `instr*`를 실행 가능한 focus로 사용할 때 `W REST`로 낮추는 것은, SpecTec 의미를 깨는 임의의 하드코딩이라기보다 Maude의 `assoc id: eps` matching 문제를 피하기 위한 executable encoding이라고 설명할 수 있다.

발표할 때는 이렇게 말하면 된다.

> SpecTec 표기상으로는 `instr*`이지만, `Step` premise의 대상이 되는 `instr*`는 실제로 한 step을 수행해야 하므로 empty sequence일 수 없습니다. Maude에서는 `WasmTerminals`가 `eps` identity를 가지기 때문에 이를 그대로 sequence 변수 하나로 두면 empty match가 생깁니다. 그래서 translator에서 `Step` premise의 focus sequence만 `W : WasmTerminal`과 `REST : WasmTerminals`로 낮춰서 non-empty임을 좌항 패턴에서 보장하려고 합니다.

---

## 8. 교수님께 보고할 내용

내일 미팅에서 다음처럼 설명하면 된다.

> 교수님 말씀대로 다시 확인해보니, baseline stack overflow의 원인은 `crl` 자체라기보다 `WasmTerminals`의 `assoc id: eps` matching 문제일 가능성이 높아 보입니다.
>
> 현재 `step-ctxt-instrs`가 `VAL INSTR INSTR1`처럼 여러 sequence 변수를 인접하게 두고 있고, 이 변수들이 모두 `WasmTerminals`입니다. 그래서 Maude가 sequence를 match할 때 `eps`를 포함한 여러 split을 만들 수 있습니다.
>
> 특히 조건 안에 `step(< Z | INSTR >) => < ZQ | INSTRQ >`가 있기 때문에, `INSTR`가 empty이거나 progress하지 않는 형태로 잡힌 split이 recursive rewrite search를 유발할 수 있습니다. 이 구조가 교수님께서 말씀하신 `f(nil) f(1234)` 문제와 같은 형태라고 이해했습니다.
>
> 현재는 `INSTR =/= eps` guard를 추가했지만, 이 guard는 match 이후 조건에서 검사되기 때문에 Maude가 `eps` split 후보를 만드는 것 자체를 막지 못합니다.
>
> 따라서 수정은 guard를 더 붙이는 방식이 아니라, recursive focus를 `INSTR : WasmTerminals` 하나로 두지 않고 `W : WasmTerminal`, `REST : WasmTerminals`로 낮춰서 Maude 좌항 패턴 단계에서 non-empty가 보장되도록 바꾸는 방향으로 진행하려고 합니다.

---

## 9. PPT에 넣을 내용

### Slide 1. 현재 증상

제목:

```text
Baseline direct crl 실행 시 stack overflow
```

내용:

```maude
rew [1] in WASM-FIB-BS :
  step(< fib-state(i32v(1)) | CTORLOCALGETA1(1) >) .
```

결과:

```text
Fatal error: stack overflow
```

발표 멘트:

> fibonacci 전체 실행이 아니라 `step(...)` 한 번에서도 stack overflow가 발생했습니다. 따라서 outer `steps` 반복 때문만은 아니고, conditional `step` rule을 적용하는 과정에서 문제가 생긴다고 볼 수 있습니다.

---

### Slide 2. 교수님 가설과 현재 Maude sequence 정의

제목:

```text
eps identity sequence matching
```

내용:

```maude
op eps : -> WasmTerminals .
op _ _ : WasmTerminals WasmTerminals -> WasmTerminals [ctor assoc id: eps] .
```

발표 멘트:

> 교수님께서 말씀하신 nil 문제와 같이, 현재 instruction sequence도 `eps`를 identity로 갖는 associative sequence입니다. 따라서 Maude가 sequence를 match할 때 empty sequence를 split 후보에 포함시킬 수 있습니다.

---

### Slide 3. 문제가 되는 baseline rule

제목:

```text
step-ctxt-instrs의 ambiguous split
```

내용:

```maude
crl [step-ctxt-instrs] :
  step(< Z | VAL INSTR INSTR1 >)
  =>
  < ZQ | VAL INSTRQ INSTR1 >
  if all-vals ( VAL ) = true
  /\ step(< Z | INSTR >) => < ZQ | INSTRQ >
  /\ ( ( VAL =/= eps ) or ( INSTR1 =/= eps ) ) = true
  /\ INSTR =/= eps .
```

발표 멘트:

> `VAL`, `INSTR`, `INSTR1`이 모두 sequence 변수이기 때문에 하나의 instruction list를 여러 방식으로 나눌 수 있습니다. `INSTR =/= eps` 조건은 있지만, 이 조건은 match 이후에 검사되므로 empty split 후보 자체를 막지는 못합니다.

---

### Slide 4. 왜 guard만으로 부족한가

제목:

```text
Guard does not prevent matching
```

내용:

```text
1. Maude first matches:
   step(< Z | VAL INSTR INSTR1 >)

2. Because of assoc id: eps, it may try splits with eps.

3. Then it checks conditions.

4. The condition itself contains recursive rewrite search:
   step(< Z | INSTR >) => < ZQ | INSTRQ >
```

발표 멘트:

> 문제는 `INSTR =/= eps`가 없는 것이 아니라, 이 조건이 너무 늦게 적용된다는 점입니다. 이미 Maude는 `eps`가 포함된 split 후보들을 만들고, 그 후보들에 대해 recursive `step` premise를 증명하려고 합니다.

---

### Slide 5. 수정 방향

제목:

```text
Non-empty focus pattern
```

현재:

```maude
step(< Z | VAL INSTR INSTR1 >)
```

수정:

```maude
var W : WasmTerminal .
var REST : WasmTerminals .

step(< Z | VAL W REST INSTR1 >)
```

조건:

```maude
step(< Z | W REST >) => < ZQ | INSTRQ >
```

발표 멘트:

> `W`는 `WasmTerminal`이므로 `eps`가 될 수 없습니다. 따라서 recursive focus인 `W REST`는 최소 하나의 instruction을 포함합니다. 이렇게 하면 empty focus가 좌항 패턴에서부터 match되지 않기 때문에 교수님께서 말씀하신 nil split 문제를 직접 막을 수 있습니다.

---

## 10. 다음 실험 계획

1. `translator_bs.ml`에서 `Step/ctxt-instrs`의 focus sequence를 `W : WasmTerminal`, `REST : WasmTerminals` 형태로 non-empty lowering한다.
2. context guard를 recursive `step` premise보다 앞에 오도록 조건 순서를 조정한다.
3. 다시 `output_bs.maude`를 생성한다.
4. 다음 최소 실험을 먼저 확인한다.

```maude
rew [1] in WASM-FIB-BS :
  step(< fib-state(i32v(1)) | CTORLOCALGETA1(1) >) .
```

현재 수정 후 이 실험은 stack overflow 없이 종료된다.

다만 결과가 아직 `step(< ... | CTORLOCALGETA1(1) >)` 그대로 남는다.

즉 nil/context self-recursion 문제는 막혔지만, `step-read-local-get`이 실제로 적용되지 않는 별도 문제가 남아 있다.

현재 확인한 membership test는 다음과 같다.

```maude
red in WASM-FIB-BS : fib-state(i32v(1)) :: State .
red in WASM-FIB-BS : CTORLOCALGETA1(1) :: Instr .
red in WASM-FIB-BS : CTORCONSTA2(CTORI32A0, 0) :: Val .
```

결과는 모두 `false`이다.

따라서 다음 단계는 stack overflow가 아니라, generated membership/type condition이 실제 runtime term에 대해 성립하지 않는 문제를 봐야 한다.

---

## 11. 주의해서 말해야 할 점

아직 이렇게 말하면 안 된다.

```text
crl로 하면 무조건 안 됩니다.
```

현재 더 정확한 표현은 다음이다.

```text
현재 direct crl encoding은 assoc id: eps sequence matching을 너무 자유롭게 열어두고 있어서 stack overflow가 납니다.
따라서 crl 자체를 포기하기 전에, recursive focus가 empty로 match되지 않도록 translator를 수정해볼 필요가 있습니다.
```

또한 이렇게 말하는 것이 좋다.

```text
교수님께서 말씀하신 nil 문제와 같은 방향으로 원인을 다시 이해했습니다.
기존에 넣은 INSTR =/= eps guard는 충분하지 않았고,
좌항 pattern 자체를 non-empty focus로 바꿔야 할 것 같습니다.
```
