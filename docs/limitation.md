# C1 limitation 정리

Updated: 2026-05-24

이 파일이 현재 C1 limitation의 기준 문서다. 오래된 batch audit 문서와
`docs/archive/` 아래 문서는 증거/기록용이다. 현재 상태를 볼 때는 이 파일과
root의 `STATUS.md`를 먼저 본다.

## 0. 현재 결론

`output_bs.maude`는 `wasm-3.0/*.spectec`에 대해 구조적 coverage가 완료된
상태다.

- source files: 21 / 21
- syntax declarations: 249 / 249
- def declarations/equations: 1272 / 1272
- relation declarations: 82 / 82
- rule declarations: 499 / 499
- strict validation source-rule targets: 281 / 281 primary `rl/crl`
- `eq/ceq ... = valid`: 없음
- `iter-empty` / `opt-empty`: 없음
- missing source construct: 현재 확인된 것 없음

다만 C1 final 관점에서 아래 항목들은 아직 limitation/debt로 남아 있다.

## 1. 우리가 쓰는 C1 isomorphism 기준

현재 프로젝트에서 말하는 isomorphic은 아래 기준이다.

1. SpecTec source에 있는 syntax / def / rule 구조와 같은 의도와 생김새로
   변환되어야 한다.
2. 변수명과 Maude 내부 이름은 달라도 된다.
3. source에 없는 추가 helper / 추가 rule / 추가 condition / 추가 function은
   C1 core에 남기지 않는다. 단, source meta-notation을 Maude에서 표현하기
   위한 substrate나 명시적으로 허용한 source-derived execution view는 예외로
   둘 수 있다.
4. SpecTec unconditional rule이면 Maude도 unconditional rule이어야 하고,
   conditional rule이면 Maude도 conditional rule이어야 한다.
5. SpecTec `def`는 Maude `eq/ceq`, SpecTec `rule`은 Maude `rl/crl`로
   내려가는 것이 원칙이다.

## 2. Non-isomorphic / 교수님 논의 필요 항목

### 2.1 label-related `step-from-step-pure-*` 20개

이 20개 rule은 SpecTec source에 직접 있는 rule이 아니다.

SpecTec source에는 아래 세 rule family가 있다.

- `Step_pure/...`: instruction sequence 자체가 pure하게 한 step 줄어드는 rule
- `Step/pure`: `Step_pure`를 전체 `Step` relation으로 올리는 rule
- `Step/ctxt-instrs`: instruction sequence 가운데 일부가 step되면 앞뒤
  context를 보존하는 rule

strict C1이라면 이 source rule 조합만으로 실행되어야 한다. 예를 들어
source 의미상으로는 아래가 되어야 한다.

```text
step(Z ; LABEL {...} BR 0) -> (Z ; eps)
```

이면:

```text
step(Z ; LABEL {...} BR 0 LOCAL.GET 1)
-> step(Z ; eps LOCAL.GET 1)
```

하지만 Maude가 associative sequence split과 conditional rewrite premise를 한
번에 안정적으로 조합하지 못해서, label/br suffix case에서 Fibonacci 실행이
멈춘다.

그래서 현재 output에는 label-related `Step_pure` rule을 `Step`으로 직접 lift한
shortcut 20개가 남아 있다.

예:

```maude
crl [step-from-step-pure-br-label-zero-ctx-suffix] :
  step((Z ; LABEL ... BR 0 SUFFIX))
  =>
  (Z ; RESULT SUFFIX)
  if ...
```

분류:

- `NON_C1_FINAL_EXEC_DEBT`
- source에는 없는 derived executable shortcut이다.
- hardcoded benchmark patch는 아니지만, strict C1 source-rule-only 기준에는
  맞지 않는다.

교수님 질문:

> Maude 실행 한계 때문에 label-related `Step_pure` rule을 `Step`으로 직접
> lift한 shortcut 20개가 필요합니다. C1에 temporary executable debt로 둘 수
> 있을까요, 아니면 C1에서는 제거하고 C2 execution layer로 보내야 할까요?

### 2.2 `$infer-*` witness inference overlay

`$infer-*`는 source에 문자 그대로 있는 relation이 아니다.

대표 source:

```spectec
rule Instrs_ok/seq:
  C |- instr_1 instr_2* : t_1* ->_(x_1* x_2*) t_3*
  -- Instr_ok: C |- instr_1 : t_1* ->_(x_1*) t_2*
  -- (if C.LOCALS[x_1] = init t)*
  -- Instrs_ok: $with_locals(C, x_1*, (SET t)*) |- instr_2* : t_2* ->_(x_2*) t_3*
```

여기서 `t_2*`는 첫 premise `Instr_ok`가 만들어내고, 다음 premise
`Instrs_ok`가 사용한다.

strict source-shaped Maude는 대략 아래처럼 생긴다.

```maude
crl [instrs-ok-seq] :
  Instrs-ok(C, INSTR1 INSTRS2, ARROW(TS1, XS1 XS2, TS3))
  =>
  valid
  if Instr-ok(C, INSTR1, ARROW(TS1, XS1, TS2)) => valid
  /\ Instrs-ok($with-locals(C, XS1, $star-prefix(SET, TS)),
               INSTRS2,
               ARROW(TS2, XS2, TS3)) => valid .
```

문제는 `TS2`다. 현재 relation encoding은 `Judgement => valid`라서
`Instr-ok(...) => valid`가 `TS2`를 결과로 반환하지 않는다. Maude가 `TS2`를
스스로 합성해야 한다.

그래서 translator는 source premise 구조를 보고 generic `$infer-*` helper를
생성한다.

```maude
$infer-instr-ok-arg2(C, INSTR1) => ARROW(TS1, XS1, TS2)
```

그리고 나서 원래 source premise도 다시 확인한다.

분류:

- `GENERIC_WITNESS_INFERENCE_OVERLAY`
- judgement/constructor hardcoding은 아니다.
- 하지만 source에는 없는 execution overlay이므로, C1 안에서 허용할지
  교수님과 논의해야 한다.

교수님 질문:

> C1의 relation을 `=> valid`로 유지하면 source premise가 만드는 witness를
> Maude가 자동으로 꺼내기 어렵습니다. `$infer-*` 같은 source-derived witness
> inference helper를 C1에 둬도 될까요, 아니면 C2 solver/execution layer로
> 분리해야 할까요?

### 2.3 Category / Sequence Sort Representation Gap

SpecTec source의 변수들은 그냥 아무 term이 아니다. category 정보가 붙어 있다.

예:

```text
instr_1  : instr
instr_2* : instr*
t_1*     : valtype*
x_1*     : idx*
```

가장 이상적인 Maude는 변수 sort 자체로 이 정보를 표현하는 것이다.

```maude
var INSTR1 : Instr .
var INSTRS2 : InstrSeq .
vars TS1 TS2 TS3 : ValtypeSeq .
vars XS1 XS2 : IdxSeq .
```

하지만 현재 output은 대부분 broad carrier인 `SpectecTerminal` /
`SpectecTerminals` 위에 올라가 있다. 그래서 아직 일부 source category 정보가
아래 형태로 남는다.

```maude
(INSTRS2 hasType list(instr)) : WellTyped
$is-spectec-numtype(TQ)
$is-spectec-vectype(TQ)
```

많이 줄인 것:

- record category guard 다수
- simple alias category guard 다수
- source-derived typed record constructor / projection / update
- source-derived typed index for composite record-field sequences

아직 남은 이유:

- `valtype*`, `instr*`, `idx*` 같은 sequence category를 하나의 broad
  `SpectecTerminals` 위에서 표현한다.
- WebAssembly source에는 `val* instr* instr_1*` 같은 mixed sequence pattern이 많다.
- 단순히 `ValSeq < SpectecTerminals`, `InstrSeq < SpectecTerminals`만 추가하면
  `__` concatenation 결과가 다시 broad sequence가 되거나 ambiguity가 커진다.
- 제대로 하려면 source-derived typed sequence / mixed sequence / nested sequence
  sort 설계가 필요하다.

분류:

- `CATEGORY_SEQUENCE_SORT_REPRESENTATION_GAP`
- source 의미를 보존하기 위한 guard지만, strict “source category = Maude sort”
  기준에는 아직 부족하다.

교수님 질문:

> C1에서 remaining `$is-spectec-*` / `_hasType_` guard를 허용할 수 있을까요?
> 아니면 typed/mixed/nested sequence sort 설계를 C1 안에서 끝내야 할까요?

## 3. 현재는 accepted로 보는 source-derived lowering

아래 항목들은 source에 문자 그대로 같은 이름이 있지는 않지만, 현재 C1에서는
accepted representation으로 둔다. 교수님이 더 strict하게 보자고 하면 다시
논의해야 한다.

### 3.1 source-star relation lowering: `Valtype-oks`, `Val-oks` 등

SpecTec의 `(premise)*` meta-notation은 Maude condition에 그대로 쓸 수 없다.
그래서 source의 `P*`는 source-style sequence judgement로 낮춘다.

예:

```maude
rl [val-oks-empty] :
  Val-oks(S, eps, eps) => valid .

crl [val-oks-cons] :
  Val-oks(S, V VS, T TS) => valid
  if Val-ok(S, V, T) => valid
  /\ Val-oks(S, VS, TS) => valid .
```

분류:

- `ACCEPTED_SOURCE_STAR_LOWERING`
- 예전의 non-source direct `Val-ok(vals*, tys*)` footer list-lift는 제거했다.
- value-list validation이 필요하면 singleton `Val-ok`가 아니라 source-star lowering
  `Val-oks`를 사용한다.

### 3.2 `$map-*`, `$valid-*`, `$result-*`, `$cont-*`

이 helper들은 source expression / source def condition을 Maude에서 실행 가능하게
보는 source-derived execution view다.

- `$map-*`: source의 `f(x*)` 또는 `f(x)^n` 같은 star-map expression lowering.
- `$valid-*`: source relation premise를 source `def`의 Boolean condition 안에서
  확인하기 위한 mirror.
- `$result-*`: output-bearing relation premise의 result witness를 꺼내는 mirror.
- `$cont-*`: source `def`를 `eq/ceq`로 유지하기 위한 continuation helper.

이 덕분에 source `def`인데 Maude `crl`로 남던 아래 labels는 더 이상 없다.

- `evalexprs-r1`
- `evalexprss-r1`
- `evalglobals-r1`
- `instantiate-r0`

분류:

- `SOURCE_DERIVED_EXECUTION_VIEW`
- arbitrary Wasm-specific shortcut은 아니다.
- 다만 교수님이 “source에 없는 helper는 전부 C2로 빼자”고 하면 다시 논의해야 한다.

### 3.3 reference/cast `otherwise` decision mirror

SpecTec의 `-- otherwise`는 plain Maude rewrite 조건으로는 실패 우선순위를
직접 표현하기 어렵다. 그래서 현재 output은 `Heaptype_sub` / `Reftype_sub`
source rule에서 만든 Boolean mirror를 사용한다.

- `$heaptype-sub?`
- `$reftype-sub?`

이 mirror는 성공 rule의 recursive `Reftype-sub => valid` 조건 앞에 빠른
`true` guard를 넣고, `-- otherwise` rule에는 같은 판단의 `false` guard를 넣는다.
이렇게 해야 negative case에서 성공 rule의 recursive subtype search가 stack overflow
로 들어가기 전에 실패하고, source의 otherwise branch가 실행된다.

분류:

- `SOURCE_DERIVED_OTHERWISE_DECISION_VIEW`
- focused reference/cast positive/negative probe는 통과한다.
- 다만 source에는 문자 그대로 없는 decision view이므로, strict C1 기준에서는
  교수님께 C1에 둘지 C2 execution layer로 보낼지 확인할 수 있다.

## 4. 현재 실행 audit 결과

최신 broad generated-rule concrete audit:

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

- `559 REDUCED`: generated concrete sample에서 실제로 실행 확인됨.
- `271 STUCK`: generated concrete sample에서는 줄어들지 않음. 하지만 이것이 전부
  rule bug라는 뜻은 아니다. source-valid context/store/module/type witness가 부족한
  sample일 수 있다.
- `0 STACK_OVERFLOW`: 이전 broad audit의 `infer-instrs-ok-arg0-r3` crash는
  제거됐다. source witness를 생산하지 않는 self-recursive `$infer-*` helper rule은
  더 이상 생성하지 않는다.
- rule count가 835에서 830으로 줄어든 것은 SpecTec source rule 삭제가 아니라
  source-absent helper overlay pruning 때문이다.

## 5. 현재 focused execution limitation

최신 focused probe matrix:

```text
artifacts/c1-probe-matrix-20260525_004421/probe_summary.md
```

결과:

- `43 PASS`
- `0 FAIL`
- `0 EXPECTED_STUCK`
- `0 STACK_OVERFLOW`

### 5.1 `infer-instrs-ok-arg0-r3`

상태:

- 이전 broad audit에서 `STACK_OVERFLOW`.
- 현재 broad rewrite audit에는 해당 helper rule이 생성되지 않는다.
- focused smoke에서도 stack overflow 없이 종료한다.

의미:

- `instr*`와 instruction type만 보고 canonical `Context C`를 추론하려고 한다.
- source에는 이 context를 어떻게 고르라는 규칙이 없다.
- 그래서 translator는 source witness를 새로 만들지 않고 같은 helper premise의
  witness를 그대로 전달하는 self-recursive `$infer-*` rule을 생성하지 않는다.
- source relation rule 자체는 그대로 남고, source-absent inference overlay만
  줄어든다.

분류:

- `RESOLVED_STACK_OVERFLOW`
- `CONTEXT_WITNESS_SYNTHESIS_REMAINS`

교수님 질문:

> 이런 context/witness synthesis를 C1의 `$infer-*` overlay로 계속 밀고 갈지,
> 아니면 C2 solver로 분리할지 결정이 필요합니다.

### 5.2 nonempty `$evalexprss` / `expr**`

source:

```spectec
def $evalexprss(z, eps) = (z, eps)
def $evalexprss(z, expr* expr'**) = (z'', ref* ref'**)
  -- if (z', ref*) = $evalexprs(z, expr*)
  -- if (z'', ref'**) = $evalexprss(z', expr'**)
```

현재:

- `evalexprss-r1`이라는 Maude `crl` label은 더 이상 없다.
- source `def -> eq/ceq` 기준은 고쳤다.
- empty case는 실행된다.
- one-const / two-const flat nonempty `$evalexprss` focused probes도 실행된다.

이유:

- source의 `expr**`는 “expression sequence들의 sequence”다.
- 현재 Maude는 대부분 flat `SpectecTerminals`로 들고 있어서 grouping이 사라진다.
- 이번 수정은 source `def` premise에서 유도되는 continuation과 flat sequence
  progress guard로 nonempty concrete path를 실행 가능하게 만든 것이다.
- 하지만 explicit empty inner group처럼 flat representation으로 표현 자체가
  사라지는 nested grouping은 별도 representation 문제가 남아 있다.

분류:

- `RESOLVED_FOCUSED_EXECUTION_PATH`
- `NESTED_SEQUENCE_GROUPING_LIMITATION`

해결 방향:

- source-derived nested sequence representation 설계.
- 단순 helper 하나 추가로 끝나는 문제가 아니다.

### 5.3 reference/cast `otherwise` negative path

상태:

- focused reference/cast positive/negative probe가 모두 통과한다.
- `step-read-br-on-cast-negative`
- `step-read-br-on-cast-fail-negative`
- `step-read-ref-test-negative`
- `step-read-ref-cast-negative`

해결:

- translator가 이미 만들던 `$heaptype-sub?` / `$reftype-sub?` decision mirror를
  `Step_read` reference/cast rule 조건에 실제로 연결했다.
- 기존에는 current binder 이름이 `-LOWS` / `-LOWF`인데 translator가 예전 suffix인
  `-S` / `-F`만 찾아서 decision guard가 삽입되지 않았다.
- 이제 성공 rule은 recursive `Reftype-sub => valid` 전에 `true` decision guard를
  확인하고, otherwise rule은 같은 판단의 `false` guard를 확인한다.

분류:

- `RESOLVED_FOCUSED_EXECUTION_PATH`
- `SOURCE_DERIVED_OTHERWISE_DECISION_VIEW`

교수님 확인 질문:

> focused execution은 통과하지만, source에는 없는 Boolean decision mirror가 C1에
> 남습니다. `-- otherwise` priority를 C1에서 이렇게 표현해도 되는지, 아니면 C2
> execution layer로 분리해야 하는지 확인하면 됩니다.

### 5.4 source-shaped invoke / outer-frame path

현재:

- `$invoke(...)` 자체는 `Config`로 rewrite된다.
- named empty-frame Fibonacci path는 result까지 간다.
- normal smoke `steps(fib-config(i32v(5)))`는 통과한다.
- fully source-shaped path `steps(fib-config-invoke(i32v(5)))`도 result까지 간다.

분류:

- `RESOLVED_FOCUSED_EXECUTION_PATH`
- `SOURCE_DERIVED_EMPTY_RECORD_CANONICALIZATION`

해결:

- source record field가 전부 `eps` 또는 recursively empty record로 채워질 수 있으면
  translator가 기계적으로 empty record constant를 만든다.
- 현재 생성되는 대표 constant:
  `$empty-moduleinst`, `$empty-frame`, `$empty-store`
- 예: source-shaped `RECFrameA2(eps, RECModuleinstA9(eps, ..., eps))`가
  `$empty-frame`으로 canonicalize되어 `Step/ctxt-frame` execution path와 맞물린다.

### 5.5 builtin backend completeness

`builtins.maude`를 추가했고, `wasm-exec-bs.maude`가 이를 load한다.

현재 최소 구현:

- `$ibits`
- `$inv-ibits`
- `$irev`
- `$lanes`
- `$inv-lanes`

분류:

- `BACKEND_BUILTIN_LIBRARY_INCOMPLETE`

해결 방향:

- SIMD, memory byte conversion, float, relaxed numeric benchmark를 실제로 넣을 때
  필요한 `hint(builtin)`을 계속 확장한다.

## 6. 현재 passing으로 보는 대표 probe

최신 focused matrix에서 passing인 대표 항목:

- `index(CTORI32A0 CTORI64A0, eps)`
- `index(CTORI32A0 CTORI64A0, 0 1)`
- `Resulttype-ok(C0, eps)`
- `Resulttype-ok(C0, i32 i32)`
- `Resulttype-sub(C0, eps, eps)`
- `Instrtype-ok(C0, arrow(eps, eps, eps))`
- `Instrtype-sub(C0, arrow(eps, eps, eps), arrow(eps, eps, eps))`
- `Instr-ok(C0, NOP, arrow(eps, eps, eps))`
- `Instr-ok(C0, UNREACHABLE, arrow(eps, eps, eps))`
- `Instr-ok/local.get`
- `Instrs-ok(C0, NOP, arrow(eps, eps, eps))`
- `Instrs-ok(C0, CONST i32 0, arrow(eps, eps, i32))`
- `Expr-ok-const`
- constant-expression `Global-ok`
- `Externaddr-ok(fib-store, FUNC 0, FUNC fib-type)`
- `Val-oks(fib-store, eps, eps)`
- `Val-oks(fib-store, CONST i32 5 CONST i32 0, i32 i32)`
- reference/cast `otherwise` positive and negative probes
- `$evalexprs(ST0, CONST i32 0)`
- `$evalexprss(ST0, CONST i32 0)`
- `$evalexprss(ST0, CONST i32 0 CONST i32 1)`
- `$invoke(...)` rewrites to `Config`
- `steps(invoke-outer-config)`
- `steps(fib-config-invoke(i32v(5)))`
- label/br suffix search
- br_if suffix search
- nop suffix search
- `steps(fib-config(i32v(5)))`

## 7. 교수님께 가져갈 질문

핵심 질문:

> C1 baseline의 acceptance criterion을 어디까지 잡아야 하나요?

선택지:

1. source-to-output structural/isomorphic correctness 중심
2. 모든 generated rule에 대해 source-valid concrete execution sample까지 요구
3. benchmark에 필요한 execution path 중심으로 검증

구체 질문:

1. label-related `step-from-step-pure-*` 20개를 C1 temporary executable debt로
   둘 수 있는가?
2. `$infer-*` witness inference overlay를 C1에 허용할 수 있는가?
3. 남은 `$is-spectec-*` / `_hasType_` guard를 C1에서 허용할 수 있는가?
4. `expr**` 같은 nested sequence representation을 C1에서 지금 설계해야 하는가?
5. reference/cast `otherwise` decision mirror를 C1에 둘 수 있는가, 아니면 C2로
   분리해야 하는가?
6. broad audit의 `271 STUCK`을 전부 source-valid sample로 분류해야 하는가, 아니면
   benchmark-driven execution validation으로 넘어가도 되는가?

## 8. 지금 당장 하지 말아야 할 것

- `271 STUCK`을 전부 rule bug라고 단정하지 않는다.
- `output_bs.maude`를 손으로 patch하지 않는다.
- init-config/frontend/model checking과 C1 isomorphism cleanup을 섞지 않는다.
- 교수님과 C1 기준을 정하기 전에 typed/mixed/nested sequence 대수 전체를 갈아엎지 않는다.

## 9. 추천 다음 순서

1. 이 문서와 `STATUS.md`를 교수님께 설명할 자료로 사용한다.
2. 먼저 C1 기준을 확정한다.
3. 기준이 “full executable C1”이면:
   - 269 stuck 분류
   - true nested `expr**` grouping이 필요한 benchmark 확인
   - arbitrary `$infer-*` witness synthesis 범위 결정
   순서로 진행한다.
4. 기준이 “structural baseline + benchmark execution”이면:
   - 현 상태를 C1 baseline으로 고정하고,
   - benchmark를 넣으면서 필요한 execution path를 고친다.
