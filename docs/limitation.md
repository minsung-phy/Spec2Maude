# C1 strict limitation 정리

Updated: 2026-05-22

이 파일이 현재 C1 limitation의 기준 문서다. 오래된 batch audit 문서는 증거/기록용이고,
지금 상태를 볼 때는 이 파일을 먼저 보면 된다.

## 현재 결론

`output_bs.maude`는 `wasm-3.0/*.spectec`에 대해 구조적 coverage가 완료된 상태다.

- source files: 21 / 21
- syntax declarations: 249 / 249
- def declarations/equations: 1272 / 1272
- relation declarations: 82 / 82
- rule declarations: 499 / 499
- strict validation source-rule targets: 281 / 281 primary `rl/crl`
- `eq/ceq ... = valid`: 없음
- `iter-empty` / `opt-empty`: 없음

즉 source construct가 아예 빠진 것은 현재 확인되지 않았다.

다만 C1 final 관점에서 아래 항목들은 아직 limitation/debt로 남아 있다.

## 1. Non-isomorphic / 교수님 논의 필요 항목과 경계 정리

### 1.1 label-related `step-from-step-pure-*` 20개

이 20개 rule은 SpecTec source에 직접 있는 rule이 아니다.

SpecTec source에는 아래 rule 조합이 있다.

- `Step_pure/...`: instruction sequence 자체가 pure하게 한 step 줄어드는 rule
- `Step/pure`: `Step_pure`를 전체 `Step` relation으로 올리는 rule
- `Step/ctxt-instrs`: instruction sequence 가운데 일부가 step되면 앞뒤 context를 보존하는 rule

strict C1이면 이 세 source rule만으로 실행되어야 한다. 하지만 Maude가 associative
instruction sequence split과 conditional rewrite premise를 한 번에 안정적으로 조합하지 못해서,
`LABEL ... BR 0 LOCAL.GET 1` 같은 label/br suffix case에서 Fibonacci 실행이 멈춘다.

그래서 현재 output에는 label-related `Step_pure` rule을 `Step`으로 직접 lift한 shortcut
20개가 남아 있다.

분류:

- `NON_C1_FINAL_EXEC_DEBT`
- hardcoded Wasm constructor patch는 아니지만, source에는 없는 derived executable shortcut이다.
- 교수님 질문: C1에 temporary executable debt로 둘지, C2 execution layer로 보낼지 결정 필요.

### 1.2 `$infer-*`

`$infer-*`는 source에 문자 그대로 있는 relation이 아니다.

예를 들어 `Instrs_ok/seq` source rule은 첫 instruction의 중간 result type `t_2*`를
premise `Instr_ok`가 만들어내고, 다음 premise `Instrs_ok`가 그 값을 사용한다.
Maude의 `Judgement => valid` encoding은 `valid`만 돌려주므로 `t_2*` 같은 witness를
자동으로 꺼내기 어렵다.

그래서 현재 translator는 source premise 구조를 보고 generic `$infer-*` helper를 생성한다.
이 helper는 먼저 witness candidate를 계산하고, 원래 source premise도 다시 확인한다.

분류:

- `GENERIC_WITNESS_INFERENCE_OVERLAY`
- judgement/constructor hardcoding은 아니다.
- 하지만 source에는 없는 execution overlay이므로 C1 core에 허용할지 교수님과 논의 필요.

### 1.3 source-style relation-star lowering: `Valtype-oks` 등

SpecTec의 `(premise)*` meta-notation은 Maude rule condition에 문자 그대로 쓸 수 없다.
따라서 source의 `P*`는 sequence judgement로 낮춘다.

예를 들어 source에 아래와 같은 반복 premise가 있으면:

```text
(Valtype_ok: C |- t : OK)*
```

현재 output은 내부 이름 `$iter-valtype-ok-...`를 쓰지 않고, source relation 이름에 가까운
sequence judgement를 생성한다.

```maude
rl [valtype-oks-empty] :
  Valtype-oks(C, eps) => valid .

crl [valtype-oks-cons] :
  Valtype-oks(C, T TS) => valid
  if Valtype-ok(C, T) => valid
  /\ Valtype-oks(C, TS) => valid .
```

분류:

- `ACCEPTED_SOURCE_STAR_LOWERING`
- 사용자의 현재 C1 기준에서는 교수님께 가져갈 non-isomorphic debt에서 제외한다.
- source에 없는 arbitrary shortcut이 아니라, source의 `*` meta-notation을 Maude sequence 위에 표현한 것이다.
- 예전의 `$iter-*` 내부 이름은 제거되었고, 현재 `output_bs.maude`에는 `$iter`가 남아 있지 않다.
- `iter-empty` / `opt-empty` derived validation rule과는 다르다. 이 lowering은 source `P*` 자체를 표현하기 위한 list judgement다.

### 1.4 남은 `$is-spectec-*` / `_hasType_` category guard

source category를 Maude sort/membership으로 표현 가능한 곳은 최대한 옮겼다.

이미 줄인 것:

- record category guard 다수
- simple alias category guard 다수
- source category subsort 일부
- `expr = instr*` 같은 sequence alias guard 일부
- `globaltype = mut? valtype` 같은 flat/mixed category는 broad carrier + source-derived predicate로 보존

아직 남은 이유:

- `valtype*`, `instr*`, `idx*`처럼 sequence category를 하나의 broad `SpectecTerminals` 위에서 표현한다.
- WebAssembly source에는 `val* instr* instr_1*` 같은 mixed sequence pattern이 많다.
- 단순히 `ValSeq < SpectecTerminals`, `InstrSeq < SpectecTerminals`만 추가하면 `__` concatenation 결과가 다시 broad sequence가 되거나, mixed sequence 때문에 ambiguity가 커진다.

이번에 줄인 부분:

- `localtype*`, `globaltype*`, `tabletype*`처럼 record field 안에 들어가는 flat composite sequence element는
  source `StructT` / `TypD` 정보를 보고 `$typed-index(sort, xs, i)`로 낮춘다.
- 예를 들어 source의 `C.LOCALS[x]`가 `localtype*` 위의 index라는 것을 알면,
  raw flat `index(value('LOCALS, C), x)` 대신 `$typed-index(localtype, value('LOCALS, C), x)`를 생성한다.
- 이 helper는 localidx/localtype 이름을 손으로 박은 특수 patch가 아니라,
  source record field의 element sort와 source category definition에서 생성된다.
- 그래서 `C.LOCALS[0] = SET i32` 형태의 local/get 검증 probe는 이제 실행된다.

분류:

- `CATEGORY_SEQUENCE_SORT_REPRESENTATION_GAP`
- source 의미를 보존하기 위한 guard지만, “unconditional source rule은 unconditional Maude rule” 기준에는 아직 완전히 맞지 않는다.
- 다만 composite record-field sequence indexing의 대표 stuck는 source-derived `$typed-index`로 해결했다.
- 향후에는 `_hasType_` / `$is-spectec-*`까지 더 줄이기 위해 typed sequence sort / mixed sequence sort 설계를 별도 단계로 검토해야 한다.

## 2. Concrete 실행 limitation

### 2.1 direct sequence-shaped `Val-ok`

아래 query는 stuck가 기대된다.

```maude
rew [100] in WASM-FIB-BS : Val-ok(fib-store, eps, eps) .
rew [100] in WASM-FIB-BS :
  Val-ok(fib-store,
    CTORCONSTA2(CTORI32A0, 5) CTORCONSTA2(CTORI32A0, 0),
    CTORI32A0 CTORI32A0) .
```

이유:

- source `Val-ok`는 singleton value validation rule이다.
- 예전에 footer에 sequence list-lift `Val-ok(vals, types)` helper가 있었지만 strict C1에서 제거했다.
- source에 없는 list-lift query를 되살리면 C1 strict 기준에 어긋난다.

분류:

- `SEQUENCE_VAL_OK_LIMITATION`

### 2.2 invoke / initial config 연결

현재 `$invoke(...)` 자체는 Config로 rewrite된다.
또 named `empty-frame` path를 사용한 일부 `steps` probe도 통과한다.

하지만 아래는 아직 stuck다.

```maude
rew [10000] in WASM-FIB-BS : steps(fib-config-invoke(i32v(5))) .
```

이유:

- `$invoke` 이후 source-shaped outer frame/context와 `steps` 연결이 아직 완전히 정리되지 않았다.
- 이건 init-config / frontend / harness 단계의 문제로 분리한다.

분류:

- `INIT_CONFIG_INVOKE_HARNESS_LIMITATION`

### 2.3 composite typed sequence index: 대표 stuck 해결

이전에는 아래 source-level probe가 stuck였다.

```maude
red in WASM-FIB-BS : index(value('LOCALS, CLOCAL), 0) .

rew [100] in WASM-FIB-BS :
  Instr-ok(CLOCAL, CTORLOCALGETA1(0), CTORARROWA3(eps, eps, CTORI32A0)) .
```

원하는 source 의미:

- `C.LOCALS`는 `localtype*`다.
- `localtype`은 `SET i32` 같은 composite source element다.
- 따라서 `C.LOCALS[0]`는 source element 하나인 `SET i32`를 돌려줘야 한다.

현재 Maude 표현:

- `localtype*`가 broad `SpectecTerminals` flat sequence 위에 표현된다.
- `SET i32`가 `CTORSETA0 CTORI32A0`처럼 두 token sequence로 놓인다.
- scalar `index(CTORSETA0 CTORI32A0, 0)`는 composite element 전체가 아니라 첫 token `CTORSETA0`만 돌려준다.

그래서 예전에는 `Instr-ok/local.get`의 source premise `C.LOCALS[x] = SET t`가 풀리지 않았다.

현재 수정:

```maude
red in WASM-FIB-BS :
  $typed-index(localtype, value('LOCALS, CLOCAL), 0) .

rew [100] in WASM-FIB-BS :
  Instr-ok(CLOCAL, CTORLOCALGETA1(0), CTORARROWA3(eps, eps, CTORI32A0)) .
```

둘 다 통과한다.

`$typed-index`는 다음처럼 생성된다.

- source record field가 `localtype*`, `globaltype*`, `tabletype*` 같은 composite element sequence인지 수집한다.
- source category definition이 flat composite element인지 확인한다.
- 해당 source sort에 대해서만 source-derived typed index equations를 생성한다.
- `globaltype = mut? valtype`처럼 optional-empty variant가 있는 경우도 source variant별 index equation을 생성한다.

남은 주의점:

- raw `index(SpectecTerminals, Nat)`는 여전히 flat carrier index다.
- source expression이 composite sequence index라는 것을 translator가 알 때만 `$typed-index`를 사용한다.
- 이것은 typed sequence sort 전체 문제를 완전히 끝낸 것은 아니고, source-derived index lowering으로 대표 stuck를 해결한 것이다.

분류:

- `FIXED_BY_SOURCE_DERIVED_TYPED_INDEX`
- 남은 broader category/sequence sort 문제는 1.4에 계속 기록한다.

### 2.4 nonempty `expr**` / nested sequence 실행 limitation

`$evalexprss`는 source에서 아래처럼 정의된다.

```spectec
def $evalexprss(z, eps) = (z, eps)
def $evalexprss(z, expr* expr'**) = (z'', ref* ref'**)
  -- if (z', ref*) = $evalexprs(z, expr*)
  -- if (z'', ref'**) = $evalexprss(z', expr'**)
```

빈 case는 실행된다.

```maude
rew [10] in C1-RULE-CONCRETE-SAMPLES : $evalexprss(ST0, eps) .
```

하지만 nonempty flat probe는 아직 source-valid nested grouping으로 실행되지 않는다.

```maude
rew [50] in C1-RULE-CONCRETE-SAMPLES :
  $evalexprss(ST0, CTORCONSTA2(CTORI32A0, 0)) .
```

이유:

- source의 `expr**`는 “expression sequence들의 sequence”, 즉 nested sequence 의미다.
- 현재 C1 Maude 표현은 대부분 broad flat `SpectecTerminals` 위에 올라가 있다.
- 그래서 `expr* expr'**`를 나눌 때 `expr* = eps`, `expr'** = 원래 입력` 같은 split이 계속 가능하다.
- 그 결과 `search =>+` 기반 broad audit에서는 stack overflow가 날 수 있고,
  focused `red` probe에서는 `$evalexprss(...)` 상태로 stuck될 수 있다.

분류:

- `NESTED_SEQUENCE_GROUPING_LIMITATION`
- `expr**` 같은 nested star/meta-sequence를 source-derived 구조로 표현하는 설계가 필요하다.
- 임시로 `expr* =/= eps` 같은 조건을 추가하면 실행은 막을 수 있지만, source 구조를 바꾸는 것이므로 현재 C1에서는 넣지 않는다.

### 2.5 runtime / module execution family의 source-valid sample 부족

전체 rule concrete audit에서 runtime `step`, `step-pure`, `step-read`, module allocation/eval family는
`NO_SOLUTION`이 많이 나온다.

중요한 점:

- 이것은 대부분 자동 sample이 정확한 store/frame/stack/module witness를 만들지 못해서 생긴다.
- 곧바로 translator bug라고 보면 안 된다.
- source-valid focused sample을 만든 뒤에도 실패하는 항목만 실제 bug/limitation으로 승격한다.

현재 focused smoke는 통과한다.

- `$expanddt(value('TYPE, fib-funcinst))`
- label/br suffix search
- `br_if` suffix search
- `nop` suffix search
- `steps(fib-config(i32v(5)))`

### 2.6 vector / numeric builtin operational limitation

아래 vector bitmask 계열은 더 이상 stack overflow를 내지 않는다.

```maude
red in WASM-FIB-BS : $ivbitmaskop(CTORXA2(CTORI32A0, 4), 0) .
red in WASM-FIB-BS : $vbitmaskop(CTORXA2(CTORI32A0, 4), 0) .
```

이번에 generic하게 고친 것:

- generated `$map-*` helper가 opaque sequence에도 무한히 펼쳐지지 않도록,
  recursive map 조건을 `S =/= eps`가 아니라 `len(S) > 0` 기반으로 바꿨다.
- `$ilt`, `$ieq`, `$ine`처럼 Bool expression을 terminal 값으로 바꾸는 source def는
  실제 Bool sort로 계산 가능한 경우에만 펼쳐지도록 generic Bool sort-safety condition을 붙였다.

그래서 `$lanes(...)`처럼 아직 backend builtin 구현이 없는 값이 들어와도 Maude가 crash하지 않고,
아래처럼 symbolic term으로 남는다.

```maude
result V128:
  $irev(32,
    $inv-ibits(32,
      $ilt(32, CTORSA0, $lanes(CTORXA2(CTORI32A0, 4), 0), 0)
      0 0 ... 0))
```

아직 남은 이유:

- source에 `def $lanes_ hint(builtin)`, `def $inv_ibits_ hint(builtin)`,
  `def $irev_ hint(builtin)`처럼 host/backend builtin으로 표시된 함수들이 있다.
- 현재 C1 translator는 source def/rule 구조를 옮기지만, 모든 numeric/vector builtin의
  실제 bit-level 구현을 제공하지는 않는다.

분류:

- `BUILTIN_NUMERIC_VECTOR_LIMITATION`
- crash는 줄였지만, 완전 계산은 builtin backend 구현 또는 C2/runtime library 설계가 필요하다.

## 3. 최신 concrete probe 결과

최신 focused probe matrix:

```text
artifacts/c1-probe-matrix-20260522_114516/probe_summary.md
```

결과:

- PASS: 27 / 31
- EXPECTED_STUCK: 4 / 31

PASS로 확인된 대표 항목:

- `index(xs, eps)`
- `index(xs, 0 1)`
- `Resulttype-ok(C0, eps)`
- `Resulttype-ok(C0, i32 i32)`
- `Resulttype-sub(C0, eps, eps)`
- `Instrtype-ok(C0, arrow(eps, eps, eps))`
- `Instrtype-sub(C0, arrow(eps, eps, eps), arrow(eps, eps, eps))`
- `Instr-ok/NOP`
- `Instr-ok/unreachable`
- `Externaddr-ok/func` with `fib-store`
- `$typed-index(localtype, value('LOCALS, CLOCAL), 0)`
- `Instr-ok/local.get`
- `Instrs-ok/NOP`
- `Instrs-ok(CONST i32 0, arrow(eps, eps, i32))`
- `Expr-ok-const(C0, CONST i32 0, i32)`
- `Global-ok` with constant expression
- `$invoke(...)` rewrites to Config
- accepted execution smokes

EXPECTED_STUCK:

- direct sequence-shaped `Val-ok` empty probe
- direct sequence-shaped `Val-ok` multi-value probe
- source-shaped invoke outer-frame path
- `steps(fib-config-invoke(i32v(5)))`

## 4. 전체 rule concrete audit 결과

최신 전체 rule audit:

```text
artifacts/rule-concrete-audit-20260522_020812/summary.md
artifacts/rule-concrete-audit-20260522_020812/rule_concrete_results.csv
```

대상:

- generated `rl/crl`: 884개
- 각 rule마다 concrete sample을 넣어 `search =>+` 실행
- 이것은 모든 input에 대한 증명이 아니라, rule별 최소 concrete 실행 probe다.

Raw result:

| status | count |
|---|---:|
| `SOLUTION` | 363 |
| `NO_SOLUTION` | 502 |
| `MAUDE_EXIT_2` | 15 |
| `STACK_OVERFLOW` | 3 |
| `TIMEOUT` | 1 |

분류 결과:

```text
artifacts/rule-concrete-classification-20260522_023538/summary.md
artifacts/rule-concrete-classification-20260522_023538/rule_concrete_classification.csv
```

해석:

- 363개는 broad generated sample로 직접 solution 확인.
- 그중 171개는 source-style relation-star lowering(`Valtype-oks` 같은 `*-oks`/`*-subs` helpers) 실행 확인이고, 9개는 `$infer-*` overlay 실행 확인이다.
- `NO_SOLUTION` 502개는 대부분 sample/context/witness 부족이다.
- `STACK_OVERFLOW` 3개 중 `expr-ok-const-r0`와 `step-read-array-fill-succ`는 broad sample bug로 확인했다.
  source-valid focused probe는 PASS다.
- `evalexprss-r1`은 빈 case는 PASS지만 nonempty flat `expr**` probe가 source-valid nested grouping으로 실행되지 않는다.
  위의 `NESTED_SEQUENCE_GROUPING_LIMITATION`으로 분류한다.
- `MAUDE_EXIT_2` 15개는 broad search sample에서 Maude internal error가 난 것이다.
  Phase 1 focused triage에서 priority 항목은 아래처럼 분류했다.

Phase 1 focused error triage:

```text
artifacts/phase1-error-triage-20260522_102830/summary.md
```

| 항목 | 결과 | 분류 |
|---|---|---|
| `expr-ok-const-r0` | source-valid `Expr-ok-const(C0, CONST i32 0, i32)` PASS | audit sample bug |
| `step-read-array-fill-succ` | source-valid `ARRAY.FILL` one-step PASS | audit sample bug |
| `clos-deftypes-r1` | source-valid `rew $clos-deftypes(...)` PASS | broad `search =>+` sample/RHS bug |
| `alloctypes-r1` | source-valid `rew $alloctypes(fib-source-type)` PASS | broad `search =>+` sample/RHS bug |
| `infer-fieldtype-ok-arg1-r0` | source-valid `$infer-fieldtype-ok-arg1(C0)` PASS | broad sample/context bug |
| `step-read-array-new-elem-alloc` | PASS after generic record variable namespace fix | generic translator bug fixed |
| `step-read-br-on-cast-succeed` | source-valid focused probe PASS after generic variable-extraction fix | generic translator bug fixed |
| `evalexprss-r1` | empty PASS, nonempty flat probe EXPECTED_STUCK | nested sequence grouping limitation |
| label/handler/return `Step_pure` family 5개 | source-valid focused probes PASS | broad sample bug |
| `step-read-br-on-cast-fail-fail` | EXPECTED_LIMITATION: subtype-negative/otherwise path can stack overflow or timeout | otherwise/negative-premise limitation |
| `step-read-return-call-ref-label` | source-valid focused probe PASS | broad sample bug |
| `step-read-return-call-ref-handler` | source-valid focused probe PASS | broad sample bug |
| `step-read-throw-ref-handler-catch` | source-valid focused probe PASS | broad sample bug |
| `step-read-struct-new-default` | source-valid focused probe PASS | broad sample bug |
| `infer-instrs-ok-arg0-r3` | focused probe remains as `$infer-instrs-ok-arg0(...)` | context witness synthesis limitation |

Generic translator bugs fixed in this phase:

1. Source-derived typed record projection equations used to reuse field variables such as `F-TYPE-0` across different record sorts.
   This could make `eleminst.TYPE` accidentally share a `Tagtype` variable and block projections like `value('REFS, RECEleminstA2(...))`.
   The generator now namespaces record field variables by source record sort, for example `F-TAGINST-TYPE-0` and `F-ELEMINST-TYPE-0`.
2. Maude variable extraction used to treat the uppercase prefix of mixed-case constructor names such as `RECContextA13(...)` as a fake variable (`RECC`).
   Because of that, a ground source context `{}` could be mistaken as an unbound witness and the generator inserted unnecessary conditions like
   `$infer-reftype-sub-arg0(rt, target) => empty-context`.
   The extractor now ignores partial uppercase matches inside mixed-case names, so ground record constructors stay ground.
3. Generated `$map-*` helpers used to unfold over opaque sequence terms because they only checked `S =/= eps`.
   The generator now unfolds map recursion only when `len(S) > 0` is operationally known.
4. Source defs that lower Bool expressions into terminal values now get a generic Bool sort-safety condition.
   This prevents ill-sorted symbolic Bool expressions, especially around vector builtins, from entering flat sequences and causing Maude stack overflow.

`step-read-br-on-cast-succeed` is now fixed:

```maude
crl [step-read-br-on-cast-succeed] :
  step-read((S ; F) ; REF BR_ON_CAST(...))
  => REF BR(l)
  if $infer-ref-ok-arg2(S, REF) => RT
  /\ Ref-ok(S, REF, RT) => valid
  /\ Reftype-sub(empty-context, RT, $inst-reftype(value('MODULE,F), RT2)) => valid
  /\ ... .
```

즉 source rule의 witness `rt`를 `Ref-ok`에서 먼저 얻고, 그 다음 `Reftype_sub`를 확인한다.
이건 특정 `BR_ON_CAST` hardcoding이 아니라, ground constructor를 fake variable로 오해하던 generic translator bug를 고친 결과다.

중요:

- “502개가 안 된다”는 뜻이 아니다.
- “자동으로 만든 임의 sample 502개가 source premise를 만족하지 못했다”에 가깝다.
- 다음 검증은 family별 source-valid sample catalog를 늘리는 방식으로 진행해야 한다.

Phase 1 위험 항목 19개 최신 해석:

- 대부분은 자동 broad sample이 틀렸고, source-valid focused probe는 통과했다.
- 2개는 실제 generic translator bug였고 수정했다:
  record field variable namespace 문제, mixed-case constructor variable extraction 문제.
- 3개는 실제 실행 limitation으로 남는다:
  `evalexprss-r1`, `step-read-br-on-cast-fail-fail`, `infer-instrs-ok-arg0-r3`.
- vector bitmask stack overflow는 generic map / Bool sort-safety fix로 crash에서 symbolic stuck로 개선했다.

`step-read-br-on-cast-fail-fail`이 남는 이유:

- source에는 `Step_read/br_on_cast_fail-succeed` 다음에 `Step_read/br_on_cast_fail-fail -- otherwise`가 있다.
- false case에서는 먼저 “cast succeed 조건이 성립하지 않음”을 확인하고 fail-fail rule로 가야 한다.
- 현재 Maude rewrite rule에는 source의 `otherwise`를 negative rewrite condition으로 정확히 표현하는 장치가 없다.
- 그래서 `ref i31`을 `ref func`으로 cast하려는 실패 case에서, 성공 rule의 `Reftype-sub({}, ref i31, ref func)` 조건을 증명하려고 들어갔다가 `Heaptype_sub/trans` 같은 recursive subtype 탐색으로 stack overflow 또는 timeout이 날 수 있다.

분류:

```text
OTHERWISE_NEGATIVE_PREMISE_LIMITATION
```

해결 방향:

- 특정 `BR_ON_CAST_FAIL` rule만 hardcoding해서 우회하면 C1 기준에 맞지 않는다.
- source `otherwise`를 Maude에서 어떻게 표현할지, 또는 C2 execution strategy로 넘길지 교수님과 논의가 필요하다.

`infer-instrs-ok-arg0-r3`가 남는 이유:

- source `Instrs_ok/frame`은 같은 context `C`에서 내부 `Instrs_ok`와
  `Resulttype_ok`를 확인한다.
- `$infer-instrs-ok-arg0`는 `instr*`와 `instrtype`만 보고 context `C`를
  만들어내려는 실행 overlay다.
- empty instruction case에서는 가능한 context가 너무 많고, source에는
  “대표 context 하나를 골라라”라는 규칙이 없다.

분류:

```text
CONTEXT_WITNESS_SYNTHESIS_LIMITATION
```

## 5. 남은 warning/advisory

안전하게 줄인 warning:

- assignment-fragment advisory: 제거됨.
- multiple distinct parses: 제거됨.
- duplicate import advisory: 제거됨.

남은 warning:

- `used-before-bound`: `load wasm-exec-bs` 기준 10개.
  대부분 validation witness, execution/module helper output witness 쪽이다.
  source premise가 conclusion에 없는 witness를 만들어야 하는 경우라서, 무작정 `:=`를 `==`로 바꾸면 실행이 깨질 수 있다.
- command-time membership warning:
  Maude builtin/pretype associative operator와 generated sequence operator `__`의 membership axiom warning이 남는다.
- `Nonfuncs` collapse advisory:
  `nonfuncs = global* mem* table* elem*` 같은 source mixed-sequence membership에서 온다.

분류:

- `WARNING_DEBT`
- 현재 accepted smoke 실행 결과는 정상이다.
- warning을 줄이는 작업은 source rule 단위로 별도 진행해야 한다.

## 6. 지금까지 generic하게 고친 것

이번 C1 pass에서 source-preserving하게 고친 대표 항목:

- strict validation lowering: 281 / 281 primary `rl/crl`
- derived `iter-empty` / `opt-empty` 제거
- footer `eq/ceq ... = valid` 제거
- generated predicate namespace를 `$is-spectec-*`로 정리
- DecD LHS argument lowering에서 `translate_arg` 사용
- sequence index `index(xs, i*)` 추가
- source set membership `x <- xs` generic lowering 추가
- constructor argument sort hint 복구
- source category subsort 복구
- optional source pattern variable refinement
- sequence alias type guard 복구 (`expr = instr*`)
- flat/mixed source category를 broad carrier + source-derived predicate로 보존
- typed record field 변수명 namespace fix:
  source-derived record projection/update/merge equations에서 field 이름이 같은 record들이 서로 다른 Maude variable sort를 갖도록 수정
- mixed-case constructor variable extraction fix:
  `RECContextA13` 같은 generated constructor를 fake variable로 오해하지 않게 해서
  `step-read-br-on-cast-succeed`의 불필요한 context inference를 제거
- `Expr-ok-const`, `Global-ok const`, `Instrs-ok CONST` focused probe 개선
- dead helper cleanup: `$cfg-state`, `$cfg-instrs`, `needs-label-ctxt`, `is-trap`, stale `VALOK-*`, duplicate `$local` footer shims 등
- `WasmTerminal/WasmType` naming을 `SpectecTerminal/SpectecType` 계열로 일반화
- header/prelude feature detection 일부 source-derived화

## 7. 교수님께 가져갈 질문

1. label-related `step-from-step-pure-*` 20개를 C1 temporary executable debt로 둘 수 있는가?
   아니면 C1에서는 제거하고 C2 execution layer로 보내야 하는가?
2. `$infer-*` witness inference overlay를 C1 core에 허용할 수 있는가?
   아니면 C2 mode-aware validation solver로 분리해야 하는가?
3. 남은 `$is-spectec-*` / `_hasType_` guard를 C1에서 허용할 수 있는가?
   아니면 typed sequence/mixed sequence sort 설계를 반드시 해야 하는가?
4. warning 10개와 command-time membership warning을 C1 known warning으로 둘 수 있는가?
   아니면 final 전에 모든 warning을 0으로 만들어야 하는가?
