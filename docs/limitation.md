# C1 limitation 정리

Updated: 2026-05-26

이 문서가 현재 C1 limitation / 교수님 논의 사항의 기준 문서다.
`docs/archive/` 아래 문서는 기록용이며, 현재 상태를 판단할 때는 이 문서와
root의 `STATUS.md`를 먼저 본다.

## 0. 현재 결론

`output_bs.maude`는 WebAssembly 3.0 SpecTec source에 대해 구조적 coverage가
완료된 상태다.

```text
source files:                    21 / 21
syntax declarations:             249 / 249
def declarations/equations:       1272 / 1272
relation declarations:            82 / 82
rule declarations:                499 / 499
strict validation rule targets:   281 / 281 primary rl/crl
missing source construct:         현재 확인된 것 없음
eq/ceq ... = valid:               없음
iter-empty / opt-empty labels:    없음
```

현재 핵심은 “source 구조를 유지하면서 Maude 실행성을 위해 필요한 최소
source-derived helper를 C1에서 허용할 수 있는가”이다.

## 1. C1 isomorphism 기준

현재 프로젝트에서 말하는 C1 isomorphic 기준:

1. SpecTec source에 있는 syntax / def / rule 구조와 의도를 보존한다.
2. 변수명과 Maude 내부 이름은 달라도 된다.
3. source에 없는 helper / rule / condition / function은 C1 core에 남기지
   않는 것이 원칙이다. 단, Maude 표현상 unavoidable하거나 교수님께 명시적으로
   허용받은 source-derived execution infrastructure는 예외로 둘 수 있다.
4. SpecTec unconditional rule이면 Maude도 unconditional rule이어야 하고,
   conditional rule이면 Maude도 conditional rule이어야 한다.
5. SpecTec `def`는 Maude `eq/ceq`, SpecTec `rule`은 Maude `rl/crl`로 내려간다.

## 2. 현재 non-isomorphic / 교수님 논의 필요 항목

### 2.1 Category / Sequence Sort Representation Gap + Generic Step-Pure Context Bridge

#### SpecTec 원본 예시

```spectec
rule Step/ctxt-instrs:
  z; val* instr* instr_1*  ~>  z'; val* instr'* instr_1*
  -- Step: z; instr* ~> z'; instr'*
  -- if val* =/= eps \/ instr_1* =/= eps
```

의미:

> 전체 instruction sequence 안에서 가운데 `instr*`만 step 가능하면,
> 앞의 `val*`와 뒤의 `instr_1*`는 그대로 두고 가운데만 바꾼다.

여기서 source category 정보는 중요하다.

```text
val*      : value sequence
instr*    : instruction sequence
instr_1*  : instruction sequence
```

#### Strict isomorphic한 Maude

strict하게는 source premise만 내려가야 한다.

```maude
crl [step-ctxt-instrs] :
  step((Z ; VALS INSTRS INSTRS1))
  =>
  (ZQ ; VALS INSTRSQ INSTRS1)
  if (VALS =/= eps \/ INSTRS1 =/= eps)
  /\ step((Z ; INSTRS)) => (ZQ ; INSTRSQ) .
```

#### 왜 strict하게만 하면 실행이 어렵나

현재 C1에서는 `val*`, `instr*`, `instr_1*`가 각각 다른 Maude sequence sort가
아니다. 대부분의 sequence가 넓은 sort로 올라간다.

```maude
SpectecTerminals
op __ : SpectecTerminals SpectecTerminals -> SpectecTerminals [assoc id: eps] .
```

그래서 Maude는 source shape:

```text
val* instr* instr_1*
```

을 category대로 안전하게 split하지 못하고 너무 많은 split을 시도한다.

원하는 split:

```text
VALS    = eps
INSTRS  = LABEL {...} BR 0
INSTRS1 = LOCAL.GET 1
```

하지만 broad `SpectecTerminals`에서는 `VALS` 자리에 instruction이 들어가는
source category상 말이 안 되는 split도 후보가 된다. 이 때문에 context rule의
condition에서 다시 `step((Z ; INSTRS))`를 증명하는 경로가 실행 중 불안정해질
수 있다.

#### 현재 output에서 어떻게 표현했나

`Step/ctxt-instrs` 본체는 source 구조대로 유지한다.

```maude
crl [step-ctxt-instrs] :
  step((Z ; VALS INSTRS INSTRS1))
  =>
  (ZQ ; VALS INSTRSQ INSTRS1)
  if $is-spectec-val-seq(VALS)
  /\ (VALS =/= eps \/ INSTRS1 =/= eps)
  /\ step((Z ; INSTRS)) => (ZQ ; INSTRSQ) .
```

추가된 부분:

```maude
$is-spectec-val-seq(VALS)
```

이것은 well-typed program 검사라기보다, `VALS` 자리에 진짜 value sequence만
오게 제한하는 sequence-shape guard다.

또한 pure step이 context 안에 있을 때 실행 경로를 안정화하기 위해 generic
bridge를 둔다.

```maude
crl [step-from-step-pure-ctxt-instrs] :
  step((Z ; VALS INSTRS INSTRS1))
  =>
  (Z ; VALS INSTRSQ INSTRS1)
  if $is-spectec-val-seq(VALS)
  /\ (VALS =/= eps \/ INSTRS1 =/= eps)
  /\ step-pure(INSTRS) => INSTRSQ .
```

이 helper가 없으면 Maude는 pure step을 context 안에서 줄이기 위해 아래 경로를
직접 찾아야 한다.

```text
step((Z ; VALS INSTRS INSTRS1))
-> step-ctxt-instrs
-> condition에서 step((Z ; INSTRS)) 증명
-> 그 안에서 step-pure(INSTRS) 찾기
```

하지만 broad sequence split 후보가 너무 많아서 이 경로가 불안정해질 수 있다.
그래서 `step-pure(INSTRS) => INSTRSQ`가 가능하면 바로:

```text
step((Z ; VALS INSTRS INSTRS1))
=> (Z ; VALS INSTRSQ INSTRS1)
```

로 줄이는 source-derived bridge를 둔다.

#### 분류

- `$is-spectec-val-seq`: source `val*` category를 broad carrier 위에서 보존하는
  최소 sequence-shape guard.
- `step-from-step-pure-ctxt-instrs`: `Step_pure`와 `Step/ctxt-instrs` 조합에서
  유도한 generic execution bridge.
- 둘 다 source에 문자 그대로 있는 이름은 아니므로 strict하게는
  non-isomorphic이다.

교수님 질문:

> 이런 source-derived sequence-shape guard와 generic execution bridge를 C1
> infrastructure로 허용할 수 있을까요?

### 2.2 `$infer-*` witness inference overlay

대표 source:

```spectec
rule Instrs_ok/seq:
  C |- instr_1 instr_2* : t_1* ->_(x_1* x_2*) t_3*
  -- Instr_ok: C |- instr_1 : t_1* ->_(x_1*) t_2*
  -- Instrs_ok: $with_locals(C, x_1*, (SET t)*) |- instr_2* : t_2* ->_(x_2*) t_3*
```

여기서 `t_2*`는 첫 premise가 만들어내고 다음 premise가 사용한다.

strict Maude shape:

```maude
crl [instrs-ok-seq] :
  Instrs-ok(C, INSTR1 INSTRS2, ARROW(TS1, XS1 XS2, TS3))
  =>
  valid
  if Instr-ok(C, INSTR1, ARROW(TS1, XS1, TS2)) => valid
  /\ Instrs-ok(..., INSTRS2, ARROW(TS2, XS2, TS3)) => valid .
```

문제는 `TS2`다. 현재 relation encoding은:

```maude
Instr-ok(...) => valid
```

형태라서 validity는 확인하지만 `TS2` 같은 witness를 결과로 반환하지 않는다.
그래서 translator가 source premise 구조에서 `$infer-*` helper를 생성한다.

예:

```maude
$infer-instr-ok-arg2(C, INSTR1) => ARROW(TS1, XS1, TS2)
```

그리고 원래 source premise도 다시 확인한다.

```maude
/\ $infer-instr-ok-arg2(C, INSTR1) => ARROW(TS1, XS1, TS2)
/\ Instr-ok(C, INSTR1, ARROW(TS1, XS1, TS2)) => valid
/\ Instrs-ok(..., INSTRS2, ARROW(TS2, XS2, TS3)) => valid
```

분류:

- source relation premise에서 기계적으로 유도된다.
- benchmark hardcoding은 아니다.
- 하지만 source에는 `$infer-*`라는 relation이 없으므로 strict하게는
  non-isomorphic이다.

교수님 질문:

> 이런 witness inference helper를 C1에 둘 수 있을까요, 아니면 C2 solver /
> execution layer로 분리해야 할까요?

## 3. Typecheck cleanup

교수님 질문:

> 이미 well-typed Wasm program이 input으로 들어온다고 가정하면, runtime에서
> typecheck를 다시 할 필요가 있는가?

현재 결론:

```text
runtime validation/category typecheck layer는 대부분 제거 가능했다.
다만 broad SpectecTerminals representation 때문에 val* prefix를 제한하는
최소 sequence-shape guard는 필요하다.
```

현재 제거된 것:

```text
SPECTEC-CATEGORIES
mb / cmb
hasType / WellTyped
대부분의 $is-spectec-*
```

현재 남은 것:

```maude
$is-spectec-val
$is-spectec-val-seq
```

이 둘은 일반적인 validation typecheck라기보다 `val* instr* instr_1*` 같은
mixed sequence split을 안정화하기 위한 runtime sequence-shape infrastructure다.

중요:

- Wasm type syntax를 삭제한 것이 아니다.
- SpecTec validation semantics를 삭제한 것이 아니다.
- runtime execution에 불필요한 generated category/typecheck layer를 줄인 것이다.

남아야 하는 것:

```text
i32, i64, functype, reftype, heaptype, blocktype
Instr-ok, Instrs-ok, Module-ok, Func-ok, Reftype-sub, Heaptype-sub
```

## 4. SpectecType / ground term universe cleanup

교수님 질문:

> `SpectecType`이 너무 넓어서 실제 의미 없는 ground type term까지 만들고 있는
> 것 아닌가?

문제였던 형태:

```maude
op iN   : SpectecTerminal -> SpectecType .
op list : SpectecTerminal -> SpectecType .
op vec  : SpectecTerminal -> SpectecType .
```

`SpectecTerminal`은 거의 모든 source/runtime term이 올라가는 큰 sort라서
아래처럼 의미 없는 term도 `SpectecType`처럼 받아들여질 수 있었다.

```maude
iN(CTORNOPA0)
list(CTORNOPA0)
fN(CTORREFCASTA1(CTORI32A0))
```

현재 수정:

```maude
sort SpectecTerminal .
sort SpectecType .
sort SpectecCategory .
subsort SpectecType < SpectecCategory .
```

`SpectecType`은 더 이상 runtime terminal이 아니다. 현재 output에는 아래 subsort가
없다.

```maude
subsort SpectecType < SpectecTerminal .
subsort SpectecTypes < SpectecTerminals .
```

source category label을 받는 helper는 `SpectecCategory`를 사용한다.

```maude
op $concat  : SpectecCategory SpectecTerminals -> SpectecTerminals .
op $disjoint : SpectecCategory SpectecTerminals -> Bool .
op $setminus : SpectecCategory SpectecTerminals SpectecTerminals -> SpectecTerminals .
```

parametric type/category constructor도 더 좁은 sort를 받는다.

```maude
op iN    : N -> SpectecType .
op vec   : Vnn -> SpectecType .
op binop : Numtype -> SpectecType .
op list  : SpectecCategory -> SpectecType .
```

결론:

> `SpectecType`을 통째로 지운 것은 아니다. 대신 runtime terminal과 source
> category/type label을 분리했고, parametric type constructor가 더 이상 아무
> `SpectecTerminal`이나 받지 않게 만들었다.

## 5. 현재 실행 audit

Broad concrete audit:

```text
artifacts/rule-concrete-audit-20260525_004500/summary.md
```

결과:

| status | count |
|---|---:|
| REDUCED | 559 |
| STUCK | 271 |
| STACK_OVERFLOW | 0 |
| MAUDE_EXIT | 0 |
| TIMEOUT | 0 |

해석:

- `559 REDUCED`: generated concrete sample에서 실제 rewrite 확인됨.
- `271 STUCK`: generated concrete sample에서 줄어들지 않음. 이게 전부 rule bug라는
  뜻은 아니다. source-valid context/store/module/type witness가 부족한 sample일
  수 있다.
- `0 STACK_OVERFLOW`: 이전 broad audit의 witness inference stack overflow는 현재
  재현되지 않는다.

Focused evidence:

- `artifacts/c1-probe-matrix-20260525_004421/probe_summary.md`
  - last all-pass focused matrix
  - `43 PASS`
- `artifacts/wasmtype-cleanup-audit-20260525_054200/summary.md`
  - typecheck / SpectecType cleanup 후 direct focused runtime checks 기록
- `artifacts/c1-probe-matrix-20260525_054128/probe_summary.md`
  - 최신 matrix지만 stale expected-result sort string 때문에 많은 FAIL이 찍힘
  - direct runtime result 기준과 구분해서 봐야 함

현재 passing으로 보는 대표 direct runtime path:

- `steps(fib-config(i32v(5)))`
- `steps(fib-config-invoke(i32v(5)))`
- `ref.test` positive / negative
- `ref.cast` positive / negative
- label/br suffix search
- br_if suffix search
- nop suffix search

## 6. 현재 known limitations

### 6.1 broad audit `271 STUCK`

`271 STUCK`은 모두 즉시 bug라고 보면 안 된다. generated sample이 source-valid
witness를 충분히 갖고 있지 않을 수 있다.

교수님께 먼저 물어볼 점:

> C1이 모든 generated rule에 대해 source-valid concrete execution sample까지
> 가져야 하는가, 아니면 structural baseline + focused benchmark execution이면
> 충분한가?

### 6.2 nested sequence `expr**`

`$evalexprss`의 flat concrete path는 실행된다. 하지만 source의 `expr**`는 진짜
nested sequence이고, current `SpectecTerminals` representation은 대부분 flat하다.
명시적 empty inner group이 필요한 benchmark가 나오면 nested sequence representation
설계가 필요하다.

### 6.3 builtin backend completeness

`builtins.maude`는 현재 focused tests에 필요한 최소 backend builtin만 구현한다.
SIMD, float, memory byte conversion, relaxed numeric benchmark를 넣으면 추가
backend가 필요할 수 있다.

### 6.4 source-derived execution views

아래 helper들은 source에 문자 그대로 같은 이름은 없지만, source expression /
source def condition / source otherwise priority를 Maude에서 실행하기 위해 둔
source-derived views다.

```text
$map-*
$valid-*
$result-*
$cont-*
$heaptype-sub?
$reftype-sub?
```

이들은 top-level non-isomorphism 발표에서는 1순위가 아니지만, 교수님이 helper
boundary를 물으면 같이 설명해야 한다.

## 7. 교수님께 가져갈 질문

핵심 질문:

> C1 baseline의 acceptance criterion을 어디까지 잡아야 하나요?

구체 질문:

1. `$is-spectec-val-seq`와 `step-from-step-pure-ctxt-instrs` 같은
   source-derived execution infrastructure를 C1에 둘 수 있는가?
2. `$infer-*` witness inference overlay를 C1에 둘 수 있는가?
3. runtime typecheck cleanup은 현재처럼 대부분 제거하고 최소 sequence-shape guard만
   남기는 것으로 충분한가?
4. typed/mixed/nested sequence sort 설계를 C1에서 지금 해야 하는가?
5. broad audit의 `271 STUCK`을 전부 source-valid sample로 분류해야 하는가?
6. benchmark-driven execution validation으로 넘어가도 되는가?

## 8. 지금 당장 하지 말아야 할 것

- `output_bs.maude`를 손으로 patch하지 않는다.
- `271 STUCK`을 전부 bug라고 단정하지 않는다.
- C1 기준 확정 전에 typed/mixed/nested sequence 대수 전체를 갈아엎지 않는다.
- init-config/frontend/model checking과 C1 isomorphism cleanup을 섞지 않는다.
- Wasm type syntax나 SpecTec validation relation을 runtime typecheck cleanup이라는
  이름으로 삭제하지 않는다.

## 9. 추천 다음 순서

1. 교수님께 C1 기준을 먼저 확정한다.
2. source-derived helper boundary를 확정한다.
3. 기준이 full executable C1이면 broad audit `271 STUCK`을 source-valid witness
   기준으로 분류한다.
4. 기준이 structural baseline + benchmark execution이면 benchmark를 넣으면서
   필요한 execution path를 고친다.
