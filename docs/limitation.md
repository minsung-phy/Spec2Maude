# C1 strict limitation 정리

Updated: 2026-05-21

이 파일이 현재 C1 limitation의 기준 문서다. 오래된 세부 audit 문서는
증거/기록용이고, 지금 상태를 볼 때는 이 파일을 먼저 보면 된다.

## 한눈에 보는 현재 결론

현재 `output_bs.maude`는 `wasm-3.0/*.spectec`에 대해 구조적 coverage는
완료된 상태다. 즉 source syntax / def / relation / rule 중 “아예 빠진 것”은
현재 확인되지 않았다.

하지만 아래 항목들은 아직 C1 final 전에 교수님과 확인하거나, 별도 단계에서
해결해야 한다.

### A. isomorphic하지 않거나 교수님 확인이 필요한 generated artifact

- label-related `step-from-step-pure-*` 20개: source rule이 아니라
  `Step_pure`를 `Step`으로 lift한 실행용 shortcut이다. 현재 Fibonacci 실행
  때문에 임시 유지 중이다.
- `$infer-*` / `-exec-tail-empty*`: source validation rule 자체는 아니고,
  witness-style premise를 실행시키기 위한 generic execution overlay다. 일부
  validation probe를 개선하지만 `Instrs-ok(CONST...)`에서는 아직 stack overflow가
  난다. C1에 둘지 C2로 보낼지 논의 필요하다.
- `$iter-*`: SpecTec의 `(premise)*` meta-notation을 Maude에서 표현하기 위한
  generic lowering이다. judgement-specific `iter-empty` rule은 아니지만,
  source에 문자 그대로 있는 rule도 아니므로 “meta-notation representation
  substrate”로 교수님 확인이 필요하다.
- 남은 `$is-spectec-*` composite/category predicates:
  `$is-spectec-val-seq`, `$is-spectec-heaptype`, `$is-spectec-typeuse`,
  `$is-spectec-reftype`, `$is-spectec-valtype`, `$is-spectec-blocktype`,
  `$is-spectec-expr`. record/simple category guard는 많이 제거했지만,
  composite/sequence category는 아직 typed-sort 설계가 더 필요하다.

### B. concrete 실행이 아직 안 되는 것으로 확인된 항목

- `Instrs-ok(C0, CONST i32 0, arrow(eps, eps, i32))`: 현재 stack overflow.
  `Expr-ok-const`와 constant-expression `Global-ok`도 이 문제를 타고 막힌다.
- sequence-shaped direct `Val-ok`, 예를 들어 `Val-ok(fib-store, eps, eps)`와
  multi-value `Val-ok(...)`: source singleton `Val-ok`에는 없는 list-lift query라
  strict C1에서는 일부러 살리지 않았다.
- `steps(fib-config-invoke(i32v(5)))`: `$invoke(...)` 자체는 Config로 rewrite되지만,
  `steps($invoke(...))`와 source-shaped outer frame path는 아직 init-config /
  invoke 연결 단계의 문제로 남아 있다.
- `evalexprss-r1`: nested `expr**` representation과 output-bearing witness
  synthesis가 동시에 걸린다.
- `$ivbitmaskop` / `$vbitmaskop` 일부: stack overflow는 제거했지만 `$lanes`,
  `$ibits`, inverse hint 쪽이 아직 완전히 executable하지 않다.

### C. 아직 실행 실패인지 샘플 문제인지 분류가 덜 된 항목

전체 artifact audit에서 나온 `NO_SOLUTION` / `STUCK` 다수는 곧바로 버그가
아니다. 자동 생성 sample이 source premise를 만족하지 못하거나, 필요한
context/store/module witness가 부족한 경우가 많다. 이 항목들은 focused
source-valid probe로 다시 확인해야 한다.

### D. 남은 Maude warning/advisory

2026-05-21 warning cleanup에서 안전하게 줄일 수 있는 warning은 줄였다.

제거된 warning family:

- `assignment condition fragment ... bound before matching`: 0개.
  source premise가 실제 binding이 아니라 이미 bound된 값을 확인하는 경우는
  Maude condition에서 equality check로 생성한다.
- `multiple distinct parses`: 0개. arithmetic / Bool / comparison / generated
  `$map-*` helper 표현을 prefix Maude operator form으로 출력해서 parser
  ambiguity를 제거했다.

현재 `load wasm-exec-bs` 기준 남은 warning family:

- `used-before-bound`: 25개. 세부적으로는 validation 6개,
  execution/def 12개, label 없는 numeric/vector helper 7개다.
  대부분 validation inference overlay, numeric/vector helper,
  allocation/eval/init helper에서 output witness를 Maude rewriting이 만들어야
  하는 경우다. 단순히 `:=`를 `==`로 바꾸면 오히려 더 위험해져서 유지했다.
- `duplicate-import-advisory`: 0개. `dsl/pretype.maude`의 list update
  operator `_[_<-_]`가 예전에는 `Nat` index 버전과 `SpectecTerminal` index
  버전으로 둘 다 있어서, `Nat < SpectecTerminal`과 만나 중복 import처럼 보였다.
  이제 `Nat < SpectecTerminal`은 `DSL-PRETYPE`이 제공하고, list update operator는
  `SpectecTerminal` index 버전 하나만 둔다. Nat-index update는 subsort 때문에
  그대로 동작한다.
- command-time membership warning: 실제 `red/search` 명령을 실행하면 Maude
  builtin/pretype associative operator에 대해
  `membership axioms are not guaranteed...` warning이 11개 출력될 수 있다.
  현재 Fibonacci smoke 결과는 정상이며, 이 warning은 `dsl/pretype` / builtin
  sort 설계 cleanup에서 따로 본다. 같은 실행 시점에
  `nonfuncs = global* mem* table* elem*`에서 온 `Nonfuncs` sequence membership
  때문에 `collapse at top` advisory 1개도 출력될 수 있다.

이번 pass에서 source-preserving하게 고친 대표 항목:

- `ListN`/fixed-length 반복 패턴의 길이 변수 바인딩을 generic RelD lowering에도
  반영했다.
- source category-pattern disjunction을 generic Bool category predicate로
  낮췄다.
- DecD의 `TypA`/syntax argument가 이미 바인딩된 type parameter를 가리킬 때
  그 mapping을 보존하도록 고쳤다.
- generated Maude expression pretty-printer가 arithmetic / Bool / comparison
  operator를 prefix form으로 출력하도록 정리했다.

즉 현재 warning은 완전히 0은 아니지만, 남은 warning은 대부분 source relation
premise가 output witness를 합성해야 하는 문제다. 숫자를 줄이기 위해 무작정
condition을 바꾸는 것은 C1 실행을 깨기 쉬우므로, 남은 warning은 source rule
단위로 하나씩 판다.

#### 남은 `used-before-bound` 25개를 지금 유지하는 이유

이 25개는 단순 pretty-printing 문제가 아니다. 공통 원인은 source premise가
conclusion에 없는 중간값을 만들어야 하는데, 현재 C1의 rewrite-condition 실행
방식이 그 witness를 자동 합성하지 못한다는 점이다.

분류:

- validation witness 6개:
  `deftype-sub-super`, `instr-ok-block`, `instr-ok-loop`, `instr-ok-if`,
  `instr-ok-try-table`, `module-ok-r0`.
  예를 들어 `Instr_ok/block`의 `Instrs_ok: ... ->_(x*) ...`에서 `x*`는 source
  premise가 만들어야 하는 annotation witness다.
- execution/def witness 12개:
  `step-read-br-on-cast-*`, `step-read-ref-*`, `allocmodule-r0`,
  `evalexprs-r1`, `evalglobals-r1`, `instantiate-r0`,
  `infer-instr-ok-arg2-*`.
  이들은 runtime type witness, eval output state, allocation result sequence
  같은 값을 premise에서 만들어야 한다.
- numeric/vector output witness 7개:
  `$vcvtop`, `$vnarrowop`, `$ivextunop`, `$ivextbinop`, `$growmem` 계열.
  vector lane sequence나 memory-size result 같은 output 값을 premise에서
  만들어야 한다.

따라서 현재 C1에서는 이 25개를 warning으로 유지하고 limitation으로 기록한다.
나중에 해결하려면 다음 중 하나가 필요하다.

1. source-preserving generic witness solver를 설계한다.
2. relation/def premise별 mode 정보를 생성해서 Maude가 어떤 값을 먼저 계산해야
   하는지 알게 한다.
3. C1은 구조 보존 baseline으로 두고, C2 execution layer에서 witness synthesis를
   담당하게 한다.

하지 말아야 할 것:

- warning을 없애려고 `:=`를 무작정 `==`로 바꾸기;
- judgement-specific helper rule 추가;
- constructor-specific shortcut 추가;
- source premise를 삭제하거나 약화하기.

### E. 지금 통과하는 핵심 smoke

- `$expanddt(value('TYPE, fib-funcinst))`
- `$invoke(fib-store, 0, vals)` 자체가 Config로 rewrite
- label/br suffix search
- br_if suffix search
- nop suffix search
- `steps(fib-config(i32v(5)))`

## 현재 C1 기준

우리가 쓰는 isomorphic 기준은 다음이다.

1. SpecTec source에 있는 syntax / def / rule 구조와 같은 의도와 모양으로 변환되어야 한다.
2. 변수명과 Maude 내부 이름은 달라도 된다. 예를 들어 `instr*`가 `INSTRS`가 되는 것은 괜찮다.
3. source에 없는 추가 helper, 추가 rule, 추가 condition, 추가 function은 C1 core에 남기면 안 된다. 단, Maude에서 SpecTec meta-notation을 표현하기 위한 unavoidable representation substrate는 명시적으로 기록하고 교수님과 확인해야 한다.
4. SpecTec rule이 premise 없는 unconditional rule이면, Maude에서도 가능하면 unconditional `rl`이어야 한다. source binder/category 때문에 붙은 guard는 Maude sort/membership으로 표현할 수 있으면 제거 대상이다.

## 현재 구조적 커버리지

`wasm-3.0/*.spectec` 전체에 대해 구조적 source coverage는 완료된 상태다.

- syntax declarations: 249 / 249
- def declarations/equations: 1272 / 1272
- relation declarations: 82 / 82
- rule declarations: 499 / 499
- missing source constructs: 0

strict validation lowering도 구조적으로 완료되어 있다.

- 281 / 281 strict validation source-rule targets가 primary Maude `rl` / `crl`로 생성된다.
- `output_bs.maude`에 `eq` / `ceq ... = valid`는 남아 있지 않다.
- 예전 judgement-specific `iter-empty` / `opt-empty` derived validation rule은 남아 있지 않다.

현재 invariant:

```bash
rg -n -e '^[[:space:]]*(eq|ceq) .* = valid' output_bs.maude
rg -n -e 'iter-empty|opt-empty' output_bs.maude
rg -n -e 'step-from-step-pure-' output_bs.maude | wc -l
rg -n -e 'Func-ok|Instrs-ok|Module-ok|Externaddr-ok|fib|CTORI32A0' translator_bs.ml
```

기대값:

- `eq/ceq ... = valid`: no output
- `iter-empty` / `opt-empty`: no output
- `step-from-step-pure-*`: 20
- forbidden translator hardcoding: no output

## 현재 isomorphic하지 않거나 교수님 확인이 필요한 것

### 1. label-related `step-from-step-pure-*` 20개

남아 있는 가장 큰 non-C1-final debt다.

이 rule들은 SpecTec source rule이 아니다. `Step_pure` rule을 `Step`으로 lift한 실행용 shortcut이다.

현재 상태:

- non-label `step-from-step-pure-*` shortcut은 제거되어 있다.
- label-related shortcut 20개만 남아 있다.
- 예: `step-from-step-pure-br-label-zero-ctx-suffix` 계열.

왜 남아 있나:

- source-shaped `Step/ctxt-instrs` rule 자체는 생성되어 있다.
- direct `step-pure(label(... br 0)) => eps`는 성공한다.
- 하지만 Maude가 `step((Z ; label(... br 0) local.get 1))`에서 필요한 associative split과 conditional rewrite premise를 source-shaped 단일 rule만으로 안정적으로 조합하지 못한다.
- 이 shortcut을 제거하면 label/br suffix search와 Fibonacci 실행이 깨진다.

분류:

- `NON_C1_FINAL_SCAFFOLD`
- 현재 accepted execution 때문에 임시 유지.
- C1 final 전에 제거하거나, C2 execution layer debt로 명확히 분리해야 한다.

교수님께 물어볼 질문:

> source-shaped `Step/ctxt-instrs`는 보존하되 Maude 실행 한계 때문에 label-related `step-from-step-pure-*` 20개를 C1에 임시 debt로 남겨도 되는가? 아니면 C1은 실행성이 떨어져도 strict source rule만 남기고, 이 shortcut은 C2로 보내야 하는가?

### 2. `$infer-*` / `-exec-tail-empty*` validation execution overlay

이것도 source rule 자체는 아니다.

목적:

- `Instrs-ok/seq`처럼 중간 witness가 있는 source premise를 Maude rewriting에서 실행시키기 위한 generic execution overlay다.
- 예: `TS2`가 첫 premise에서 만들어지고 다음 premise에서 소비된다.

현재 output에는 다음 계열이 있다.

- `$infer-<relation>-argN`
- `-exec-tail-emptyN`

이것들은 judgement 이름이나 constructor를 하드코딩한 것은 아니고, source relation structure에서 generic하게 생성된다. 하지만 SpecTec source에 있는 primary rule은 아니므로 strict C1 관점에서는 교수님 확인이 필요하다.

현재 문제:

- simple probe는 일부 좋아졌다.
- `Instrs-ok(C0, CTORNOPA0, arrow(eps, eps, eps))`는 성공한다.
- 하지만 `Instrs-ok(C0, CONST i32 0, arrow(eps, eps, i32))`는 현재 stack overflow가 난다.
- 원인은 `Instrs-ok/sub` execution overlay가 non-empty value-producing sequence에서 principal type inference가 안 된 상태로 다시 같은 `Instrs-ok`를 재귀적으로 시도하기 때문이다.
- 예전 `$exec-<relation>-argN` bridge rule은 relation 자체를 한 번 더 `valid`로 만드는 duplicate execution rule이라서 제거했다. 현재는 source premise 내부 witness 계산에 필요한 `$infer-*` helper만 남긴다.
- `$infer-*` helper 사이 의존성이 누락되어 Maude가 `no parse` / `bad token` warning을 내던 문제는 고쳤다. 이제 필요한 `$infer-*` operator declaration을 닫힌 집합으로 먼저 생성한다.

분류:

- `NON_C1_FINAL_BUT_SOURCE_DRIVEN_EXECUTION_OVERLAY`
- C1에 둘지, C2로 분리할지 결정 필요.

### 3. `$iter-*` relation-star meta-lowering

SpecTec source에는 `(premise)*` 같은 meta-notation이 있다. Maude에서는 이를 그대로 쓸 수 없어서 현재 `$iter-*` helper rule로 낮춘다.

중요한 점:

- 예전 `resulttype-ok-r0-iter-empty0` 같은 judgement-specific derived rule은 제거됐다.
- 현재 `$iter-*`는 source meta-notation `(J(...))*`를 표현하기 위한 generic lowering이다.
- 따라서 old helper-heavy shortcut보다는 source-preserving에 가깝다.

그래도 `$iter-*` 자체는 SpecTec source relation rule 이름 그대로는 아니므로, “C1에서 meta-notation lowering helper를 허용할지”는 교수님과 확인해야 한다.

분류:

- `GENERIC_SPECTEC_META_LOWERING`
- 현재는 C1 representation substrate로 두는 것이 현실적이다.

### 4. 남아 있는 `$is-spectec-*` category predicates

`$is-spectec-*`를 최대한 줄였다.

이미 제거된 대표 binder-only guard:

- `$is-spectec-context`
- `$is-spectec-store`
- `$is-spectec-frame`
- `$is-spectec-moduleinst`
- `$is-spectec-funcinst`
- `$is-spectec-idx`
- `$is-spectec-labelidx`
- `$is-spectec-localidx`
- `$is-spectec-packtype`

주의: `$is-spectec-numtype` / `$is-spectec-vectype` predicate 자체는 여전히
생성될 수 있다. 이는 binder-only guard가 아니라 source의
`t' = numtype \/ t' = vectype` 같은 category-pattern disjunction을 Bool 조건으로
표현하기 위한 것이다.

현재 남은 predicate family:

- `$is-spectec-val-seq`
- `$is-spectec-heaptype`
- `$is-spectec-typeuse`
- `$is-spectec-reftype`
- `$is-spectec-valtype`
- `$is-spectec-blocktype`
- `$is-spectec-expr`

왜 아직 남아 있나:

- record category는 source-derived typed record sort로 바꿔서 제거했다.
- simple zero-arity category도 least sort/subsort 쪽으로 많이 줄였다.
- 하지만 `instr`, `expr`, `valtype`, `heaptype`, `reftype`, `typeuse`, `blocktype` 같은 composite/sequence category는 아직 broad `SpectecTerminal` / `SpectecTerminals` substrate와 섞여 있다.
- 이들을 무작정 Maude sort로 좁히면 sequence AC matching, membership, validation execution overlay가 충돌해서 divergence가 생긴다.

현재 대표적인 좋은 형태:

```maude
rl [instr-ok-nop] :
  Instr-ok(C, CTORNOPA0, CTORARROWA3(eps, eps, eps))
  =>
  valid .
```

즉 source에서 premise 없는 `Instr_ok/nop`은 현재 Maude에서도 unconditional `rl`이다.

남은 작업:

- composite syntax constructor의 result/argument sort를 더 source-derived하게 정밀화해야 한다.
- 그 후 source binder type만 표현하던 `$is-spectec-*` guard를 더 제거할 수 있다.

분류:

- 일부는 `GENERIC_SPECTEC_PRELUDE_OK`
- 일부는 `C1_ISOMORPHISM_GAP`
- 더 줄이려면 typed syntax/category 설계가 필요하다.

### 5. Step wrapper infrastructure

`StepConf`, `StepPureConf`, `StepReadConf`, `StepsConf` 같은 wrapper sort는 현재 프로젝트에서 의도적으로 쓰는 Maude relation-compilation substrate다.

사용자가 명시적으로 “이건 non-isomorphic으로 보지 않아도 된다”고 정한 항목이다.

분류:

- `REPRESENTATION_SUBSTRATE_OK`

## 현재 실행 limitation

아래는 concrete probe 기준으로 확인된 실행 limitation이다.

### 1. `Instrs-ok` non-empty value-producing sequence

실패 probe:

```maude
rew [100] in C1-PROBE-TERMS :
  Instrs-ok(C0,
    CTORCONSTA2(CTORI32A0, 0),
    CTORARROWA3(eps, eps, CTORI32A0)) .
```

결과:

- stack overflow

원인:

- `Instrs-ok/sub` execution overlay가 principal type을 확정하지 못한 상태에서 다시 같은 `Instrs-ok`를 재귀적으로 호출한다.
- `NOP`처럼 `eps -> eps`인 경우는 통과하지만, `CONST`처럼 stack result를 만드는 instruction sequence에서 문제가 드러난다.

영향:

- `Expr-ok-const`
- `Global-ok` with constant expression

관련 failing probes:

```maude
rew [100] in C1-PROBE-TERMS :
  Expr-ok-const(C0, CTORCONSTA2(CTORI32A0, 0), CTORI32A0) .

rew [100] in C1-PROBE-TERMS :
  Global-ok(C0,
    CTORGLOBALA2(CTORMUTA0 CTORI32A0, CTORCONSTA2(CTORI32A0, 0)),
    CTORMUTA0 CTORI32A0) .
```

가능한 해결 방향:

- `Instrs-ok/sub`의 execution overlay가 “inference가 실제로 성공했을 때만” 동작하도록 해야 한다.
- 단순히 judgement-specific special case를 추가하면 C1 기준에 맞지 않는다.
- generic mode-aware validation solver 또는 C2 execution layer로 분리할 가능성이 높다.

### 2. sequence-shaped direct `Val-ok`

실패 probe:

```maude
rew [100] in C1-PROBE-TERMS : Val-ok(fib-store, eps, eps) .

rew [100] in C1-PROBE-TERMS :
  Val-ok(fib-store,
    CTORCONSTA2(CTORI32A0, 5) CTORCONSTA2(CTORI32A0, 0),
    CTORI32A0 CTORI32A0) .
```

원인:

- SpecTec source의 `Val-ok`는 singleton value judgement다.
- 예전에 footer에 있던 sequence list-lift `Val-ok(vals, types)`는 source rule이 아니라 실행 편의 helper였다.
- strict C1에서 제거했다.

현재 상태:

- singleton `Val-ok(fib-store, CONST i32 5, i32)`는 source rule로 처리 가능하다.
- sequence-shaped direct query는 C1 core에서 일부러 살리지 않는다.

분류:

- `SEQUENCE_VAL_OK_DIRECT_QUERY_LIMITATION`

### 3. `steps(fib-config-invoke(i32v(5)))` / invoke path

현재 `$invoke(...)` 자체는 rewrite로 config까지 간다.

성공 probe:

```maude
rew [100] in C1-PROBE-TERMS :
  $invoke(fib-store, 0, i32v(5) i32v(0) i32v(1)) .
```

실패 probe:

```maude
rew [10000] in C1-PROBE-TERMS :
  steps(fib-config-invoke(i32v(5))) .
```

원인:

- `steps(fib-config-invoke(i32v(5)))` 자체는 현재 `steps($invoke(...))` 형태에서 멈춘다. 즉 `steps` wrapper 안에서 `$invoke` rewrite가 먼저 일어나지 않는다.
- `$invoke(...)`를 별도로 rewrite해서 나온 source-shaped outer frame config를 `steps(...)`에 넣어도, 그 다음에는 `Step/ctxt-frame` / `steps-trans` conditional composition 문제가 남는다.
- 같은 inner frame을 named harness `empty-frame`으로 둔 probe는 성공한다. 따라서 문제는 Fibonacci body 자체가 아니라 invoke/source-shaped outer frame path다.

성공 probe:

```maude
rew [1000] in C1-PROBE-TERMS :
  steps(invoke-outer-config-named-empty-frame) .
```

분류:

- `INVOKE_UNDER_STEPS_LIMITATION`
- `STEP_CTXT_FRAME_EXECUTION_LIMITATION`
- init-config/frontend 단계에서 다시 봐야 한다.

### 4. 전체 `output_bs.maude` concrete artifact audit 결과

`scripts/audit_output_bs_total_concrete.py`는 `output_bs.maude`의 모든 `op` / `eq` / `ceq` / `mb` / `cmb` / `rl` / `crl` artifact를 추출하고, 각 artifact마다 concrete Maude command를 생성해서 독립 Maude process에서 실행한다.

최신 전체 audit:

```bash
python3 scripts/audit_output_bs_total_concrete.py --timeout 2
```

결과 artifact:

```text
artifacts/output-bs-total-audit-20260521_012550/
```

검사 수:

| kind | count |
|---|---:|
| op | 1202 |
| eq | 997 |
| ceq | 280 |
| mb | 424 |
| cmb | 118 |
| rl | 110 |
| crl | 774 |
| **total** | **3905** |

결과:

| status | count |
|---|---:|
| PASS | 2892 |
| KNOWN_LIMITATION | 41 |
| NO_SOLUTION | 653 |
| STUCK | 312 |
| STACK_OVERFLOW | 3 |
| MAUDE_EXIT_2 | 4 |

주의:

- `PASS`는 해당 concrete probe가 Maude에서 결과를 냈다는 뜻이다.
- `KNOWN_LIMITATION`은 이미 이 문서에 적힌 limitation/debt와 일치한 경우다.
- `NO_SOLUTION`은 곧바로 “rule이 틀렸다”는 뜻이 아니다. 샘플이 조건을 만족하지 못했거나 concrete witness/context/store가 부족한 경우가 많다.
- `STUCK`도 대부분 membership/category sample이 부정확한 경우다. source-valid sample로 재확인해야 한다.
- `STACK_OVERFLOW`는 우선 조사 대상이다. 다만 자동 샘플이 source premise를 만족하지 않는 값을 만든 경우도 있으므로, 반드시 focused probe로 재확인해야 한다.
- `MAUDE_EXIT_2` / Maude internal error는 probe가 malformed source shape를 만든 경우에도 발생할 수 있다. 예: `$clos-deftypes(fib-type CTORI32A0)`처럼 `deftype*` 자리에 잘못된 원소를 섞은 샘플.

7개 위험 실패 focused triage 최신 결과:

- `$concatn`: 실제 generic lowering bug였다. `w^n` 길이 조건과 tail sequence
  변수 sort를 보정해서 stack overflow는 제거했다.
- `$ivbitmaskop`, `$vbitmaskop`: stack overflow 자체는 제거했다.
  translator가 source의 non-variable `e*`를 generic `$map-*` star-map으로,
  `e^n`를 generic `$repeat(e,n)`로 낮추도록 보강했기 때문이다. 예를 들어
  `$ilt(..., c_1, 0)* ++ (0)^(32-M)`는
  `$map-Silt-a4-s2(..., c_1*, 0) $repeat(0, 32-M)` 형태가 된다.
  하지만 완전한 값 계산은 아직 limitation이다. 남은 원인은
  `$ibits(32,c) = bits`의 source `hint(inverse $inv_ibits_)`를 Maude 조건
  solving에서 operational하게 쓰지 못하고, `$lanes` / `$ibits` 계열 builtin
  의미가 현재 prelude에 충분히 실행 가능하게 구현되어 있지 않기 때문이다.
  이 부분은 vector-specific shortcut으로 때우지 않고 generic inverse-hint /
  builtin lowering 과제로 남긴다.
- `clos-deftypes-r1`: source-valid `rew $clos-deftypes(fib-type fib-type)`는
  Maude result를 낸다. 기존 `MAUDE_EXIT_2`는 자동 audit의 RHS-search sample
  문제였다.
- `step-read-array-new-elem-alloc`: source-shaped elem store와 `n = 1`
  sample에서는 solution이 나온다. 기존 `MAUDE_EXIT_2`는 sample 문제였다.
- `alloctypes-r1`: source-valid `rew $alloctypes(fib-source-type)`는 Maude
  result를 낸다. 기존 `MAUDE_EXIT_2`는 자동 audit의 RHS-search sample 문제였다.
- `evalexprss-r1`: 아직 limitation이다. source type `expr**`가 flat
  `SpectecTerminals`로 낮아져 recursive split에서 empty/non-progress split을
  선택할 수 있다. 추가로 바로 아래 source def `$evalexprs`의 premise
  `Eval_expr: z; expr ~>* z'; ref`는 Maude rewriting이 `z'`와 `ref`를
  역으로 합성하지 못한다. Exact output을 주면 `Eval-expr`는 `valid`로
  줄어들지만, output witness를 변수로 둔 `search Eval-expr(..., ZQ, REF)
  =>* valid`는 solution이 없다. 즉 이 family는
  `NESTED_SEQUENCE_REPRESENTATION_LIMITATION`과
  `OUTPUT_WITNESS_SYNTHESIS_LIMITATION`이 동시에 걸려 있다.

  임시 실험으로 `Eval-expr` premise를 직접 `steps((z ; expr)) => (z' ; ref)`
  로 펼치고, `expr**`의 첫 조각을 non-empty처럼 취급하면 concrete
  `$evalexprs` / `$evalexprss` probe는 통과한다. 하지만 이 방식은 source의
  `Eval_expr` premise를 그대로 보존하지 않고, `expr**`의 group boundary를
  정확히 표현하지 못하므로 strict C1-final fix로 넣지 않았다. C1-compatible
  방향은 `T**` 같은 nested sequence를 source-derived group representation으로
  표현하거나, C2 execution layer에서 output-bearing relation premise solver를
  두는 것이다.

상세 보고서:

```text
docs/archive/current-c1/dangerous_failure_triage.md
```

이미 known limitation으로 잡힌 family:

- `Instrs-ok(C0, CONST i32 0, arrow(eps, eps, i32))`: stack overflow.
- `Expr-ok-const(C0, CONST i32 0, i32)`: 위 `Instrs-ok` 문제를 타고 stack overflow.
- `Instr-ok/local.get`류: `C.LOCALS[x] = SET t`에서 source의 한 원소 `SET t`가 flat Maude sequence `CTORSETA0 t` 두 토큰으로 표현되어, 기존 `index(..., x)`가 한 토큰만 돌려주는 문제가 있다.
- `Blocktype-ok/typeidx`, `Instr-ok/call`, `Instr-ok/br-on-null` 등 context lookup 기반 rule들은 richer source-shaped context sample이 필요하다. 일부는 진짜 lookup/index representation limitation이고, 일부는 자동 샘플 품질 문제다.

accepted Fibonacci execution에는 현재 영향을 주지 않는다. 별도 concrete harness/probe가 필요하다.

상세 보고서:

```text
docs/archive/current-c1/output_bs_total_audit_report.md
artifacts/output-bs-total-audit-20260521_012550/summary.md
artifacts/output-bs-total-audit-20260521_012550/test_results.csv
```

## 현재 성공하는 대표 concrete probes

최신 확인 artifact:

```text
artifacts/c1-probe-matrix-20260521_005302/probe_summary.md
```

`scripts/run_c1_probe_matrix.py` 기준 성공:

- `index(CTORI32A0 CTORI64A0, eps)`
- `index(CTORI32A0 CTORI64A0, 0 1)`
- `index(value('LOCALS, C0), eps)`
- `Resulttype-ok(C0, eps)`
- `Resulttype-ok(C0, i32 i32)`
- `Resulttype-sub(C0, eps, eps)`
- `Instrtype-ok(C0, arrow(eps, eps, eps))`
- `Instrtype-sub(C0, arrow(eps, eps, eps), arrow(eps, eps, eps))`
- `Instrtype-ok(C0, arrow(i32, eps, i32))`
- `Instrtype-sub(C0, arrow(i32, eps, i32), arrow(i32, eps, i32))`
- `Instr-ok(C0, NOP, arrow(eps, eps, eps))`
- `Instr-ok(C0, UNREACHABLE, arrow(eps, eps, eps))`
- `Externaddr-ok(fib-store, FUNC 0, FUNC fib-type)`
- `Instrs-ok(C0, NOP, arrow(eps, eps, eps))`
- `Expr-ok(C0, NOP, eps)`
- `$invoke(fib-store, 0, vals)` rewrites to `Config`
- `$expanddt(value('TYPE, fib-funcinst))`
- label/br suffix search
- br_if suffix search
- nop suffix search
- `steps(fib-config(i32v(5)))`

## 전체 rule 실행 검증 방법

완전한 의미의 “모든 syntax/def/rule이 모든 가능한 input에서 잘 돈다”는 자동으로 증명할 수 없다. 상태 공간과 witness 공간이 무한하고, 많은 rule은 concrete store/context/module이 필요하다.

대신 현재는 두 종류의 audit을 제공한다.

### 1. Concrete probe matrix

```bash
scripts/run_c1_probe_matrix.py
```

각 probe를 독립 Maude process로 실행한다. 하나가 stack overflow가 나도 나머지는 계속 돈다.

결과는:

```text
artifacts/c1-probe-matrix-*/probe_results.csv
artifacts/c1-probe-matrix-*/probe_summary.md
```

### 2. 모든 `rl/crl` concrete-sample applicability audit

```bash
scripts/audit_output_bs_rules_concrete.py --timeout 3 --max-variants 3
```

`output_bs.maude`의 모든 `rl/crl` 라벨을 뽑고, 각 rule의 generated LHS에 concrete 샘플 값을 넣어서 generated RHS로 한 번 이상 rewrite 가능한지 search를 시도한다.

결과는:

```text
artifacts/rule-concrete-audit-*/rule_concrete_results.csv
artifacts/rule-concrete-audit-*/summary.md
```

해석:

- `SOLUTION`: concrete sample search에서 적용 가능성이 확인됨.
- `NO_SOLUTION`: concrete witness/context/store가 없거나 샘플이 조건을 만족하지 못함. 바로 버그는 아님.
- `STACK_OVERFLOW`: 우선 조사 대상.
- `TIMEOUT`: 우선 조사 대상.

### 3. 전체 artifact concrete audit

```bash
python3 scripts/audit_output_bs_total_concrete.py --timeout 2
```

이 스크립트는 `rl/crl`뿐 아니라 `op`, `eq`, `ceq`, `mb`, `cmb`까지 모두 대상으로 삼는다. 각 artifact의 generated Maude command는 `artifacts/output-bs-total-audit-*/maude-tests/`에 남는다.

해석:

- 이건 “전체 output이 모든 가능한 input에서 옳다”는 증명이 아니다.
- 하지만 현재 우리가 자동으로 확인할 수 있는 가장 넓은 concrete 실행 audit이다.
- `NO_SOLUTION`/`STUCK` 항목은 다음 triage 대상이고, source-valid focused sample로 다시 확인해야 한다.

## 다음 작업 순서 제안

1. 이 파일과 `STATUS.md` 기준으로 현재 C1 상태를 커밋한다.
2. warning cleanup을 진행한다.
3. header/footer cleanup을 계속한다.
4. generated prelude를 더 세분화해서, 실제 source가 쓰는 sequence/record/meta
   feature에 따라 필요한 조각만 emit하도록 만든다.
5. 남은 `$is-spectec-*` guard를 composite category typed-sort 설계로 더 줄인다.
6. `Instrs-ok/sub` execution overlay recursion을 C1-compatible하게 고칠 수 있는지 따로 판다.
7. 20개 label-related `step-from-step-pure-*`를 다시 제거할 수 있는 source-preserving `Step/ctxt-instrs` 실행 방식을 찾는다.
8. init-config/frontend는 그 다음 단계에서 한다.

## Header/footer/pretype cleanup 현황

2026-05-21 cleanup에서 C1이 실제로 쓰지 않는 hand-written pretype 잔재를
제거했다.

제거한 것:

- `dsl/pretype.maude`의 legacy typecheck predicates:
  - `is-type`
  - `are-types`
  - `are-mixed`
- `dsl/pretype.maude`의 legacy `DSL-EXEC` evaluation-context module:
  - `Env`, `Stage`, `InstrsContext`
  - `LabelContext(s)`, `FrameContext(s)`
  - `stage:`, `context:`, `emptylabel`, `emptyframe`, `_@_`, `_#_`
- `translator_bs.ml` header의 source-absent fixed `SpectecType` constants:
  - `w-N`, `w-M`, `w-K`, `w-n`, `w-m`, `w-X`, `w-C`, `w-I`,
    `w-S`, `w-T`, `w-V`, `w-b`, `w-z`, `w-L`, `w-E`
  - 이들은 output에 선언만 되고 실제 사용처가 없었다.
- `translator_bs.ml` header의 unused record helper declaration:
  - `_ =++ _`
  - 실제 record update는 generated `DSL-RECORD`의 source-representation
    operator `_[._=++_]`를 사용한다.

source-derived로 바꾼 것:

- active C1 `output_bs.maude`는 더 이상 `load dsl/pretype`으로 hand-written
  pretype 파일을 읽지 않는다.
- `translator_bs.ml`이 generic `DSL-TERM`, `DSL-PRETYPE`, `DSL-RECORD` 모듈을
  generated output 앞부분에 직접 emit한다.
- 따라서 `dsl/pretype.maude`는 현재 active C1 dependency가 아니라
  legacy/reference copy에 가깝다.
- prelude 생성은 이제 source feature를 본다.
  - `StructT`/record syntax가 있으면 `DSL-RECORD`를 emit하고 `SPECTEC-CORE`가
    그것을 include한다.
  - record syntax가 없는 spec에서는 이 record prelude 조각을 생략할 수 있는
    구조가 됐다.
  - generated body/token output을 scan해서 실제로 쓰이는 header 조각만 emit한다.
    현재 feature-gated 대상은 `w-bool`, `_hasType_`/`WellTyped`, `index(xs,i*)`,
    `$repeat`, `slice`, `$star-prefix`/`$star-unprefix`, set-membership `_<-_`,
    `merge`, wildcard `any`, Step wrapper infrastructure, and source
    sequence-category predicates다.
  - `$is-spectec-val-seq`는 더 이상 footer에 val 전용으로 박힌 고정 helper가
    아니다. source lowering 중 `X*` category guard가 실제로 필요할 때
    `$is-spectec-<X>-seq` 형태를 등록해서 emit한다. 현재 Wasm output에서는
    source가 요구하는 남은 sequence category guard가 `val*`라서 결과 이름이
    `$is-spectec-val-seq`인 것이다.
  - 예전 footer에 있던 `$subst-typeuse`, `$subst-valtype`, `$subst-subtype`
    sequence-lift overload는 제거했다. source element-level substitution def는
    그대로 남고, source expression의 `f(x*)` / `f(x)^n` 같은 star-map 모양에서
    generic `$map-*` helper를 생성한다.
  - 예전 frame 전용 footer shim은 제거했다. 이제 frame literal은 source
    `syntax frame = { LOCALS ..., MODULE ... }`에서 생성되는 `RECFrameA2`와
    그 projection/update equation을 그대로 사용한다.
  - 즉 P4처럼 Step relation이나 Wasm frame helper를 쓰지 않는 spec에서는 해당
    header/footer 조각을 emit하지 않는 방향으로 구조가 바뀌었다.
  - `SpectecTerminals` sequence carrier는 현재 translator의 기본 term-list
    representation이라 아직 항상 emit된다. 이것까지 완전히 feature-gated로
    줄이는 일은 다음 단계다.
- 예전 header에는 `Nat < Labelidx`, `Nat < Localidx`, `Nat < Addr` 같은
  Wasm index/address subsort 목록이 직접 박혀 있었다.
- 이제 이 목록은 source syntax alias graph에서 생성한다.
  예를 들어 `idx = u32`, `u32 = uN(32)`, `labelidx = idx`,
  `addr = nat` 같은 SpecTec 선언을 보고 필요한 `subsort Nat < ...`를 낸다.
- 따라서 P4/generalization 관점에서 “Wasm 이름을 header에 직접 나열한
  하드코딩” 하나를 줄였다.

제거 이유:

- 현재 generated `output_bs.maude`와 `wasm-exec-bs.maude`가 이 선언들을 쓰지
  않는다.
- C1은 source-derived `mb/cmb`, relation `rl/crl`, and direct execution rules를
  사용한다.
- `DSL-EXEC`는 예전 evaluation-context 실험용 구조였고, 현재 C1의
  `Step/ctxt-*` source-shaped lowering과 연결되어 있지 않다.

아직 남은 필수/보류 prelude substrate:

- `SpectecTerminal`, `SpectecTerminals`, `SpectecType`, `SpectecTypes`
- `eps`, sequence concatenation, `len`, `index`
- record `item`, `value`, update operators
- generated header의 `Judgement`, `valid`
- Step relation이 source에 있을 때만 emit되는 `StepConf` wrappers
- generated source-meta helpers such as `index(xs, i*)`, `slice`, `$repeat`,
  `$star-prefix`, `$star-unprefix`
- `w-bool`: SpecTec Bool 계산 결과를 terminal로 다시 넣기 위한 현재 Maude
  representation wrapper다. 실제 generated numeric/Bool defs에서 사용 중이라
  이번 cleanup에서는 제거하지 않았다.
- `EXP`: source의 `exp`/floating numeric condition lowering이 아직 어색하게
  남긴 header constant다. 현재 `fNmag`/`SUBNORM` 계열 조건에서 사용된다. 아직
  제거하지 않았고, source-derived numeric exponent lowering으로 바꿀 수 있는지
  별도 audit이 필요하다.
- `CTORLABELLBRACERBRACEA3`, `CTORFRAMELBRACERBRACEA3`,
  `CTORHANDLERLBRACERBRACEA3`의 precise op signature override: source syntax에서
  유도하는 실험을 했지만, 전체 CTOR signature를 source sort로 정밀화하면 Maude
  preregularity warning이 늘고 `$expanddt`/Fibonacci 실행이 깨졌다. 그래서 현재는
  이 세 execution-critical signature override를 유지한다. source-derived로 바꾸려면
  overlapping constructor overload와 sequence/list carrier 설계를 먼저 해결해야 한다.

이들은 지금 C1 실행과 source meta-expression lowering에 필요하다. 다만 P4나
다른 SpecTec으로 확장하려면 다음 단계에서 generated prelude를 feature-gated로
더 쪼개야 한다. 예를 들어 source가 record를 쓰지 않으면 `DSL-RECORD`를 emit하지
않고, source가 sequence를 쓰지 않으면 sequence helper를 최소화하는 식이다.
