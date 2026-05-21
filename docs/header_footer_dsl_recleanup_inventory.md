# Header / Footer / DSL Recleanup Inventory

목적: `translator_bs.ml` 안에 남아 있는 header/footer/dsl 성격의 출력 조각을
분류해서, 무엇을 없앨 수 있고 무엇은 아직 남겨야 하는지 구분한다.

기준:

- `REMOVE_NOW`: 현재 source에도 없고 사용처도 없어서 바로 제거 가능.
- `KEEP_AS_GENERIC_SUBSTRATE`: source에는 직접 없지만 Maude backend 표현을 위해 필요한 일반 substrate.
- `MAKE_MORE_SOURCE_DERIVED`: 지금도 source 의미를 표현하지만, feature detection이나 생성 위치를 더 source AST 기반으로 개선할 수 있음.
- `DEFER_TO_C2`: C1 source-isomorphic core보다는 실행/분석 계층에서 다루는 것이 자연스러움.
- `MOVE_TO_PROFILE_OR_HARNESS`: Wasm 실행 또는 benchmark/harness 쪽으로 분리해야 함.
- `KEEP_BUT_DISCUSS`: 지금 제거하면 실행이 깨지거나 설계 결정이 필요해서 교수님과 논의할 항목.

## 요약

지금 해야 하는 일은 “header/footer/dsl을 전부 삭제”가 아니다.
아래처럼 나눈 뒤, generic substrate는 유지하고, source에서 derive 가능한 부분은
점점 source AST 기반 생성으로 옮기고, 실행 전용 scaffolding은 C2/profile/harness로
분리하는 것이다.

| 그룹 | 현재 판단 | 바로 삭제 가능? | 다음 액션 |
| --- | --- | --- | --- |
| `SpectecTerminal`, `SpectecTerminals`, `SpectecType`, `SpectecTypes` | Maude backend carrier | 아니오 | 유지. P4에도 쓸 generic 이름으로 이미 개선됨 |
| `eps`, sequence concatenation `__`, `len`, scalar `index` | sequence representation substrate | 아니오 | 유지. 나중에 typed sequence 설계로 정밀화 |
| record substrate: `RecordItem`, `RecordItems`, `item`, `value`, record update | generic record substrate | 아니오 | 유지. source가 필요한 record 기능별로 emit |
| source record constructors: `RECContextA13`, `RECFrameA2`, ... | source-derived | 아니오 | 유지 |
| `w-bool` | Bool-as-terminal wrapper | 아니오 | source output에서 필요할 때만 emit. 더 AST 기반 feature detection 가능 |
| `_hasType_`, `WellTyped` | sequence/parametric category representation gap | 아니오 | typed sequence/category 설계 전까지 유지, 교수님 논의 |
| `Judgement`, `valid` | RelD relation compilation substrate | 아니오 | 유지 |
| `index(xs, i*)` overload | source meta-expression `xs[i*]` lowering | 아니오 | 유지. 문자열 scan 대신 AST feature detection으로 개선 |
| `$repeat` | source meta-expression `e^n` lowering | 아니오 | 유지. AST feature detection으로 개선 |
| `slice` | source meta-expression `xs[i:n]` lowering | 아니오 | 유지. AST feature detection으로 개선 |
| `$star-prefix`, `$star-unprefix` | source star-map / flat prefix constructor lowering | 아니오 | 유지. typed sequence/star-map refactor 후보 |
| `_<-_` | source set-membership meta-expression lowering | 아니오 | 유지. AST feature detection으로 개선 |
| `merge` | source record merge/composition lowering | 아니오 | 유지. AST feature detection으로 개선 |
| `any` | source wildcard/hole lowering | 아니오 | 유지 if source uses `_` holes |
| `StepConf`, `StepPureConf`, `StepReadConf`, `StepsConf` | execution relation wrapper substrate | 아니오 | 사용자가 non-isomorphic으로 보지 않기로 한 substrate. Step relation이 있을 때만 emit |
| `step`, `step-pure`, `step-read`, `steps` wrappers | source Step relation을 Maude rewrite로 실행하기 위한 substrate | 아니오 | 유지. 나중에 relation-wrapper generation 일반화 가능 |
| `$infer-*` | witness inference execution overlay | 아니오 | C1/C2 경계 논의. 현재는 실행성 때문에 유지 |
| `$iter-*` relation-star helpers | source `P*` premise 실행 helper | 아니오 | source meta-lowering 성격. derived validation shortcut은 아니지만 교수님 논의 필요 |
| `$map-*`, `$unmap-*` expression-star helpers | source `e*` map lowering | 아니오 | source meta-lowering 성격. 필요시 더 generic하게 정리 |
| `$is-spectec-*` predicates | 남은 category guard | 아니오 | 이미 많이 줄였음. typed sequence/category sort 설계 전까지 일부 유지 |
| 20 `step-from-step-pure-*` label shortcuts | non-C1-final executable debt | 아니오 | 현재 P0 limitation. C1에 둘지 C2로 보낼지 교수님 논의 |
| `fib-*`, `i32v`, `fib-config`, benchmark terms | benchmark harness | 아니오, core에서는 분리 | `wasm-exec-bs.maude` / harness로 유지 |
| `EXP` | source numeric def에서 쓰이는 free constant | 지금 바로 삭제 금지 | provenance 재확인 후 source-derived variable/constant 처리 개선 후보 |

현재 검사 기준으로 `REMOVE_NOW`로 확정한 header/footer/dsl 항목은 없다.
이미 이전 cleanup에서 dead helper는 제거되었다:

- `$cfg-state`
- `$cfg-instrs`
- `needs-label-ctxt`
- `is-trap`
- `_shape-x_`
- footer `= valid` duplicates
- footer `Val-ok` sequence lift
- footer `$local` / `$with-local` duplicate shims
- footer `$subst-*` hardcoded sequence lifts
- old `$mk-frame` adapter

## 상세 분류

### 1. Generic backend substrate

분류: `KEEP_AS_GENERIC_SUBSTRATE`

대상:

- `SpectecTerminal`
- `SpectecTerminals`
- `SpectecType`
- `SpectecTypes`
- `eps`
- sequence concatenation `__`
- `len`
- scalar `index`
- `RecordItem`
- `RecordItems`
- `item`
- `value`
- record update forms

이것들은 SpecTec source에 직접 `syntax SpectecTerminal`처럼 적혀 있는 것은 아니다.
하지만 Maude backend에서 SpecTec term, term sequence, record를 표현하려면 필요한
표현 substrate다.

즉 “source-derived syntax/rule”은 아니지만, “backend representation”으로는
필수다. P4로 가도 이런 계층은 이름만 generic이면 필요하다.

현재 상태:

- 예전 `WasmTerminal` / `WasmType` 이름은 `SpectecTerminal` / `SpectecType`로 바뀌었다.
- `dsl/pretype.maude`를 따로 load하는 구조가 아니라, translator가 generated prelude를 emit한다.
- record prelude는 source가 record를 쓸 때만 emit된다.
- record prelude 내부도 한 덩어리가 아니라 기능별로 나뉜다.
  - record literal/canonicalization이 필요하면 `item`, `{_}`를 emit한다.
  - record projection이 필요하면 `value`를 emit한다.
  - record update가 필요하면 `_[._<-_]`와 `_++_`를 emit한다.
  - record extension이 필요하면 `_[._=++_]`를 emit한다.
  - sequence element update가 필요하면 `_[_<-_]`를 emit한다.

다음 개선:

- sequence가 없는 spec에서는 `SpectecTerminals`를 얼마나 줄일 수 있는지 확인.
- typed sequence sort 설계를 하면 `SpectecTerminals` broad carrier 의존을 줄일 수 있다.

### 2. Source meta-expression helpers

분류: `MAKE_MORE_SOURCE_DERIVED`

대상:

- `index(xs, i*)`
- `$repeat(e, n)`
- `slice(xs, i, n)`
- `$star-prefix`
- `$star-unprefix`
- `_<-_`
- `merge`
- `any`

이것들은 source에 같은 이름으로 항상 존재하는 def는 아니다. 하지만 source의
meta-expression을 Maude에서 실행하려고 필요하다.

예:

- SpecTec `xs[i*]` -> Maude `index(xs, is)`
- SpecTec `e^n` -> Maude `$repeat(e, n)`
- SpecTec `xs[i:n]` -> Maude `slice(xs, i, n)`
- SpecTec `(SET t)*` 같은 flat prefix star pattern -> Maude `$star-prefix(SET, t*)`

현재 문제:

- 일부 feature detection이 아직 generated text/string scan에 의존한다.
- 더 좋은 방향은 SpecTec AST를 scan해서 “이 source가 어떤 meta-expression을 쓰는지” 보고 emit하는 것.

바로 삭제하면 안 되는 이유:

- 삭제하면 source meta-expression이 Maude에서 실행되지 않는다.
- 이들은 judgement-specific hardcoding이 아니라 generic meta-lowering에 가깝다.

다음 개선:

- `prelude_features_of_source`를 문자열 scan 중심에서 AST visitor 중심으로 바꾼다.
- 각 helper가 어떤 source meta-expression 때문에 emit됐는지 report할 수 있게 만든다.

### 3. Relation / execution wrappers

분류: `KEEP_AS_GENERIC_SUBSTRATE` 또는 `KEEP_BUT_DISCUSS`

대상:

- `Judgement`
- `ValidJudgement`
- `valid`
- `StepConf`
- `StepPureConf`
- `StepReadConf`
- `StepsConf`
- `step`
- `step-pure`
- `step-read`
- `steps`
- `Config`, `State`, `Store`, `Frame` composition operators

`Judgement` / `valid`는 SpecTec relation rule을 Maude rewrite result로 표현하기
위한 generic substrate다.

`StepConf` 계열은 source `Step` relation을 Maude rewrite engine에서 안정적으로
실행하기 위한 wrapper substrate다. 사용자가 이미 “이건 non-isomorphic으로 보지
않아도 됨”이라고 정한 항목이다.

다음 개선:

- 지금은 `source_has_step_relations`로 Step relation이 있을 때만 emit한다.
- 장기적으로는 특정 `Step` 이름에 덜 묶이게 relation wrapper generation을 일반화할 수 있다.
- 다만 현재는 accepted execution smoke와 직접 연결되어 있으므로 삭제 대상이 아니다.

### 4. C1 / C2 경계 항목

분류: `KEEP_BUT_DISCUSS` 또는 `DEFER_TO_C2`

대상:

- `$infer-*`
- `$iter-*`
- `$map-*`
- `$unmap-*`
- 남은 `$is-spectec-*`
- `_hasType_` / `WellTyped`

#### `$infer-*`

source relation premise가 output witness를 만들어야 하는 경우가 있다.
예를 들어 `Instrs_ok/seq`의 `t_2*`는 첫 premise에서 생기고 다음 premise에서
사용된다.

Maude의 `Relation(...) => valid` 구조만으로는 이 witness를 잘 찾지 못해서,
현재는 source rules에서 generic하게 `$infer-*` helper를 생성한다.

이건 Wasm-specific hardcoding은 아니지만 source rule 자체도 아니다.
따라서 C1에 남길지, C2 execution layer로 보낼지 교수님 논의가 필요하다.

#### `$iter-*`

source의 `P*` premise를 실행하기 위한 generic relation-star helper다.
예전 forbidden `iter-empty` validation rule과는 다르다. 이것은 특정 validation
rule을 하나 더 복제한 것이 아니라 source meta-premise `P*`를 실행 가능하게
낮춘 것이다.

그래도 source에 직접 `$iter-*`라는 relation은 없으므로 C1/C2 경계 논의 대상이다.

#### `$map-*` / `$unmap-*`

source expression `e*`를 flat Maude sequence 위에서 map/unmap하기 위한 helper다.
예전 hardcoded `$subst-typeuse`, `$subst-valtype`, `$subst-subtype` footer lift는
제거되었고, 현재는 source expression-star에서 생성된다.

즉 지금 형태는 더 source-derived해졌지만, helper 자체는 source에 직접 있는 이름은
아니므로 generic meta-lowering으로 설명해야 한다.

#### `$is-spectec-*`, `_hasType_`

source category annotation을 Maude sort로 완전히 표현하지 못하는 부분에 남아 있다.
record/simple alias category는 많이 제거되었다.

남은 대표 원인:

- `valtype*`, `instr*`, `idx*` 같은 typed sequence category
- `numtype \/ vectype` 같은 category disjunction
- runtime/execution matching에서 너무 좁은 sort를 쓰면 regression이 나는 category

다음 개선:

- source-derived typed sequence sort 설계.
- constructor signature까지 source argument type에 맞게 정밀화.
- 그 뒤 `_hasType_` / `$is-spectec-*`를 더 줄인다.

### 5. Non-C1-final executable debt

분류: `DEFER_TO_C2` 또는 `KEEP_BUT_DISCUSS`

대상:

- 20 label-related `step-from-step-pure-*`

의미:

- source에는 직접 없는 shortcut이다.
- `Step_pure` label rule을 `Step` context로 직접 lift한 실행용 scaffolding이다.
- strict source-shaped `Step/pure` + `Step/ctxt-instrs` 조합만으로 Maude가
  label/br suffix case를 안정적으로 실행하지 못해서 남아 있다.

현재 판단:

- 이게 가장 큰 non-C1-final debt다.
- 제거 시 accepted Fibonacci execution이 깨지는 것이 확인되었다.
- 교수님과 “C1에 temporary executable debt로 둘지, C2로 보낼지” 논의 필요.

### 6. Wasm execution / benchmark harness

분류: `MOVE_TO_PROFILE_OR_HARNESS`

대상:

- `wasm-exec-bs.maude`
- `fib-store`
- `fib-module`
- `fib-moduleinst`
- `fib-config`
- `fib-config-invoke`
- `i32v`

이들은 `output_bs.maude` strict source lowering core가 아니라 실행 smoke와 benchmark
확인을 위한 harness다.

다음 개선:

- core generated output과 benchmark harness를 계속 분리한다.
- P4/generalization에서는 이런 부분이 profile/harness로 빠져야 한다.

### 7. 현재 cleanup candidate

분류: `MAKE_MORE_SOURCE_DERIVED`

우선순위:

1. `prelude_features_of_source`를 string scan에서 AST scan으로 교체.
2. `$infer-*`, `$iter-*`, `$map-*`가 각각 어떤 source premise/expression 때문에
   생성됐는지 trace metadata를 남김.
3. `EXP` provenance 확인. 현재 `$fNmag` 계열 source numeric rule에서 쓰이는
   free constant처럼 보이므로 바로 삭제 금지.
4. Step wrapper generation을 `Step`, `Step_pure`, `Step_read`, `Steps` 이름에
   덜 묶이게 일반화할 수 있는지 설계.
5. typed sequence / precise constructor signature refactor는 별도 큰 작업으로 분리.

현재 적용된 1차 cleanup:

- `index(xs, i)`, `slice(xs, i, n)`, `x <- xs`, record composition `e1 ++ e2`,
  wildcard `_`, fixed repetition `e^n`에 대해서는 source AST scan 단계에서
  feature flag를 기록한다.
- `$star-prefix` / `$star-unprefix`, `_hasType_` / `WellTyped`, `w-bool`도
  generated-output string scan이 아니라 실제 lowering 과정에서 필요해진 순간
  feature flag를 기록한다.
- 기존 generated-output string scan fallback은 `uses_sequence_index`, `uses_repeat`,
  `uses_slice`, `uses_set_membership`, `uses_merge`, `uses_any`에만 안전장치로 남겨
  두었다. 이유는 이미 생성된 helper block 안에서 helper가 다시 helper를 요구하는
  경우까지 놓치지 않기 위해서다.
- 따라서 이번 변경은 semantics를 바꾸는 cleanup이 아니라,
  header/footer/dsl emission 결정을 source-derived 쪽으로 한 단계 옮긴 것이다.

현재 적용된 2차 cleanup:

- `DSL-RECORD`를 통째로 고정 출력하던 구조를 줄였다.
- translator가 source/translation AST에서 record literal, record projection,
  record update, record extension, sequence update 사용 여부를 기록한다.
- `generated_record_prelude_module`은 이 feature flag에 따라 필요한 선언과
  방정식만 출력한다.
- WebAssembly source는 record를 많이 쓰기 때문에 `DSL-RECORD` 자체는 여전히
  출력된다. 하지만 이제 이것은 “항상 같은 record prelude 전체를 박아 넣는”
  방식이 아니라, source가 실제로 요구한 record 기능 조각들을 조합하는 방식이다.
- 이 변경 뒤에도 C1 invariant는 유지된다:
  - `eq/ceq ... = valid` 없음
  - `iter-empty` / `opt-empty` 없음
  - label-related `step-from-step-pure-*`는 기존 documented debt 20개 유지
  - accepted C1 regression 통과

현재 적용된 3차 cleanup:

- header의 `Common variables` 구역을 줄였다.
- 특정 helper에서만 쓰이는 변수는 해당 helper block 가까이로 이동했다.
  - `INDEX-I`, `INDEX-TS`, `INDEX-IS`는 `index(xs, i*)` helper block 안에서 선언.
  - `REPEAT_N`, `REPEAT_ELEM`은 `$repeat` helper block 안에서 선언.
  - `SLICE_I`, `SLICE_N`, `SLICE_ELEM`, `SLICE_REST`는 `slice` helper block 안에서 선언.
  - `STAR-PREFIX`, `STAR-ELEM`, `STAR-REST`는 `$star-prefix` / `$star-unprefix` block 안에서 선언.
  - `LIST-TY`, `LIST-TS`는 generic list type witness footer block 안에서 선언.
  - `W`, `TS`는 source-derived sequence-category predicate footer block 안에서 선언.
- `EXP`는 더 이상 무조건 emit하지 않고, generated body에서 실제로 쓰일 때만 emit한다.
  WebAssembly numeric source에서는 현재 실제로 쓰이므로 `output_bs.maude`에는 남아 있다.
- 아직 `T : SpectecTerminal` 같은 아주 넓은 common variable은 남아 있다. 현재 source-generated
  membership/predicate equations에서 실제로 사용되기 때문에 바로 제거하지 않는다.

## Helper provenance snapshot

아래 항목은 “source에 같은 이름의 def가 있어서 나온 것”이라기보다,
SpecTec source meta-expression을 Maude에서 표현/실행하기 위해 생성되는 generic
lowering substrate다. 현재는 가능하면 source AST 또는 lowering event에서 feature flag를 켠다.

| helper | source-derived reason | 현재 emit 기준 |
| --- | --- | --- |
| `index(SpectecTerminals, SpectecTerminals)` | source `xs[i*]` 형태의 sequence index meta-expression | `IdxE` AST 또는 generated helper fallback |
| `$repeat` | source `e^n` fixed repetition | `IterE(..., ListN ...)` AST |
| `slice` | source `xs[i:n]` slicing | `SliceE` AST 또는 generated helper fallback |
| `$star-prefix`, `$star-unprefix` | source `(K x)*` 같은 flat prefix constructor-star pattern | `star_prefix_text` / `star_unprefix_text` lowering event |
| `_hasType_`, `WellTyped` | parametric category / `list(category)` guard 표현 | `type_guard` 또는 `translate_typd`에서 실제 `hasType` 생성 시 |
| `w-bool` | Bool expression이 terminal context로 들어가는 경우 | `wrap_bool TermCtx` lowering event |
| `value` | source field projection `.FIELD` 또는 source-derived typed record projection | record projection feature |
| `_[._<-_]` | source record update path | record update feature |
| `_[._=++_]` | source record extension path | record extension feature |
| `_[_<-_]` | source sequence index/slice update path | sequence update feature |

## 결론

현재 “바로 삭제 가능한 dead header/footer/dsl 항목”은 새로 발견되지 않았다.
이미 확실한 dead/helper duplicate는 앞선 cleanup에서 제거되었다.

지금 남은 것은 대부분 세 부류다.

1. Maude backend가 SpecTec term/sequence/record/relation을 표현하기 위해 필요한
   generic substrate.
2. Source meta-expression을 실행하기 위한 generic lowering helper.
3. C1/C2 경계에서 교수님과 결정해야 하는 execution overlay.

따라서 다음 실제 작업은 삭제가 아니라:

1. feature detection을 AST-derived로 바꾸기,
2. helper provenance를 source 위치와 연결하기,
3. C2로 뺄 execution overlay를 분리 설계하기,
4. typed sequence / precise constructor signature refactor를 따로 설계하기.
