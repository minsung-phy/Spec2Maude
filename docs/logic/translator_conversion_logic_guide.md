# Translator 변환 로직 가이드 (처음 보는 사람용)

이 문서는 `translator.ml`의 "변환 로직"만 빠르게 이해하도록 만든 요약 가이드입니다.
핵심은 한 줄입니다.

- 입력: IL AST (`Il.Ast.def list`)
- 출력: Maude 모듈 문자열 (`output.maude` 본문)

---

## 1. 먼저 큰 그림: `translate`가 전부 조립한다

`translate` 함수의 실제 파이프라인은 아래 5단계입니다.

1. 타입 환경 구성: `build_type_env defs`
2. 프리스캔: `scan_def`로 토큰/호출/생성자 수집
3. 본 번역: `translate_definition`으로 `TypD | DecD | RelD` 처리
4. 재정렬/보정: 선언부와 식/규칙부 분리 + 충돌 제거
5. 문자열 합치기: `header + declarations + equations + footer`

즉 "핵심 변환"은 2~4단계입니다.

---

## 2. 프리스캔 단계: 왜 먼저 훑나?

목적: 나중에 식을 번역할 때 선언 누락으로 깨지지 않게 사전 선언을 만든다.

`scan_state`가 모으는 것:

- `tokens`: 식/패턴에서 본 토큰
- `ctors`: 타입 variant 생성자 이름
- `calls`: `CallE` 호출 시그니처 `(이름, arity)`
- `bool_calls`: Bool 문맥에서 호출된 함수
- `dec_funcs`: 이미 `DecD`로 정의된 함수

이걸로 생성되는 것:

- `build_token_ops`: `ops ... : -> WasmTerminal [ctor] .`
- `build_call_ops`: helper 호출 `op` 자동 선언
  - bool 문맥 호출은 return sort를 `Bool`로 선언

핵심 포인트:

- `tokens - ctors`만 토큰 상수로 선언한다.
- 이미 `DecD`로 정의된 함수는 helper 자동선언에서 제외한다.

---

## 3. 변환의 기본 데이터 구조: `texpr`

```ocaml
type texpr = { text : string; vars : string list }
```

- `text`: Maude 텍스트
- `vars`: 식 내부에서 발견한 변수들

왜 중요한가?

- 규칙/방정식 생성 시 `if` 조건과 `:=` 바인딩을 만들려면
  "어떤 변수가 이미 바운드인지"가 필요하다.
- 전역 push/pop 대신, 하위 식 결과를 상위 식으로 순수하게 전달한다.

자주 쓰는 결합기:

- `tconcat`, `tjoin2`, `tjoin3`, `tmap`

---

## 4. 식 번역(`translate_exp`): AST를 문자열로 바꾼다

`translate_exp ctx e vm`의 3개 인자 의미:

- `ctx`: `BoolCtx | TermCtx`
  - Bool 문맥이 아니면 bool 식을 `w-bool (...)`로 감싼다.
- `e`: 변환할 IL expression
- `vm`: 변수명 매핑(바인더 이름 -> Maude 변수명)

중요 규칙 몇 개:

- `VarE`:
  - `vm`에 있으면 매핑된 이름 사용
  - 아니면 sanitize/대문자화 규칙으로 변수화
- `CallE`:
  - 함수명은 기본적으로 `$` 접두로 호출
- `CaseE`:
  - 가능하면 정규 생성자명 `CTOR...A<arity>` 사용
  - 아니면 mixfix interleave로 원형 보존
- `CmpE`, 논리 연산:
  - Bool 문맥 처리 + `vars` 누적
- `IterE`:
  - `*`, `+`, `?` suffix 매핑
  - `ListN`은 `(countVar, seqVar)`를 전역 accumulator에 기록

`ListN` 기록의 이유:

- step 규칙 생성 시 `N := len(seq)` 조건을 자동 추가하기 위함

---

## 5. 전제(premise) 스케줄링: `:=` 먼저, Bool 조건 나중

이 파일이 어려운 핵심 원인입니다. 핵심만 잡으면 됩니다.

전제는 2종류로 분해됩니다.

- `PremEq`: 동치 비교/let에서 얻은 매치 가능 항목
- `PremBool`: 일반 Bool 조건

`classify_prem` + `schedule_prems`의 역할:

1. 현재 bound 집합으로 "지금 평가 가능한 전제"를 먼저 고른다.
2. 한쪽이 신선 변수이고 반대편이 이미 bound면 `X := ...` 형태로 승격한다.
3. 바인딩이 늘어나면 다음 전제가 풀릴 수 있으므로 반복한다.

효과:

- 단순 `==`를 무조건 Bool 검사로 내지 않고,
  가능한 경우 패턴 바인딩(`:=`)으로 바꿔 규칙 적용력을 높인다.

---

## 6. 정의별 번역 디스패치: `translate_definition`

- `TypD` -> `translate_typd`
- `DecD` -> `translate_decd`
- `RelD` ->
  - 이름이 `Step | Step-pure | Step-read`면 `translate_step_reld`
  - 아니면 `translate_reld`

즉 변환 로직의 본체는 4개 핸들러입니다.

### 6.1 교수님 설명용 수도코드 (핵심만)

아래만 설명해도 "본 번역 로직"은 전달됩니다.

```text
function translate_definition(ss, def):
  match def.kind:
    case RecD:
      return concat(map(child -> translate_definition(ss, child), def.children))

    case TypD:   # syntax 변환
      return translate_typd(def.id, def.params, def.insts)

    case DecD:   # def 변환
      return translate_decd(ss, def.id, def.params, def.result_typ, def.insts)

    case RelD:   # rule 변환
      name = sanitize(def.id)
      if name in {"Step", "Step-pure", "Step-read"}:
        return translate_step_reld(name, def.rules)   # rl/crl 실행 규칙
      else:
        return translate_reld(def.id, name, def.rules) # eq/ceq Bool 관계

    case GramD or HintD:
      return ""
```

### 6.2 syntax 변환 수도코드 (`TypD`)

```text
function translate_typd(id, params, insts):
  name = sanitize(id)
  type_sort = sort_of_type_name(id)
  is_parametric = (params is not empty)

  emit sort/subsort/op declarations for type

  for inst in insts:
    match inst.deftyp:
      case VariantT(cases):
        for case in cases:
          collect constructor params and variable declarations
          lhs = canonical CTOR call OR mixfix-interleaved pattern

          prems = schedule premises
            - promote possible equalities to bindings: X := term
            - keep remaining boolean checks as conditions

          if is_parametric:
            emit eq/ceq type-ok(lhs, type_term) = true [if cond]
          else:
            emit mb/cmb lhs : type_sort [if cond]

          if optional params exist and no explicit prems:
            emit extra eps-substituted clauses

      case AliasT(typ):
        emit alias membership/type-ok constraints

      case StructT(fields):
        emit struct-style membership/type constraints
```

### 6.3 def 변환 수도코드 (`DecD`)

```text
function translate_decd(ss, id, params, result_typ, insts):
  fn = to_maude_function_name(id)   # usually "$" prefix
  arg_sorts = infer_sorts(params)
  ret_sort = infer_return_sort(result_typ, insts, ss.bool_calls)

  emit op fn : arg_sorts -> ret_sort

  for inst in insts:   # each DefD
    vm = binder variable map
    lhs = translate lhs args with TermCtx
    rhs = translate rhs with (BoolCtx if ret_sort == Bool else TermCtx)

    prems = schedule premises
      - PremEq -> try binding form: X := term
      - PremBool -> boolean condition

    cond = join(binding conditions, boolean conditions, binder type conditions)

    if cond is empty:
      emit eq  fn(lhs) = rhs
    else:
      emit ceq fn(lhs) = rhs if cond

    if owise premise exists:
      append [owise]

  emit variable declarations for bound variables
  emit constant op declarations for truly free symbols if needed
```

### 6.4 rule 변환 수도코드 (`RelD`)

일반 relation과 Step relation은 변환 세계가 다릅니다.

```text
function translate_reld(id, rel_name, rules):
  emit op rel_name : ... -> Bool

  for rule in rules:
    if premises reference Step-family relation:
      skip  # Bool relation world cannot encode this directly

    vm = binder variable map
    lhs = translate conclusion as term pattern
    prems = schedule premises (:= first, then boolean)
    cond = join(prem conditions, binder type conditions)

    if cond is empty:
      emit eq  rel_name(lhs) = true
    else:
      emit ceq rel_name(lhs) = true if cond
```

```text
function translate_step_reld(rel_name, rules):
  for rule in rules:
    if context rule:
      emit heat/cool pair
      continue

    decode conclusion into <Z | instrs> => <Z' | instrs'> shape
    translate lhs/rhs instruction sequences

    prems = schedule premises
    add extra guards when needed:
      - all-vals(...) for value sequences
      - N := len(seq) for ListN counters

    if cond is empty:
      emit rl  [name] : step(<Z | IS>) => <Z' | IS'>
    else:
      emit crl [name] : step(<Z | IS>) => <Z' | IS'> if cond

  emit WasmTerminal/WasmTerminals variable declarations
```

### 6.5 발표용 20초 요약

- `TypD`는 타입 선언과 타입 제약(`mb/cmb` 또는 `type-ok`)을 만든다.
- `DecD`는 함수 `op` 선언과 함수 식 `eq/ceq`를 만든다.
- `RelD`는 일반 규칙이면 Bool predicate `eq/ceq`, Step 계열이면 실행 규칙 `rl/crl`로 만든다.
- 세 경우 모두 premise를 먼저 재배치해 가능한 항목은 `:=` 바인딩으로 승격하고, 나머지는 `if` 조건으로 붙인다.

---

## 7. `translate_typd`: 타입 정의를 sort/member 규칙으로

핵심 산출물:

- `sort` / `subsort`
- 타입 생성자 `op ... : ... -> WasmType [ctor]`
- 멤버십/타입검사 `mb`/`cmb` 또는 `eq/ceq type-ok`

중요한 내부 아이디어:

- case 타입 파라미터를 수집해 적절한 sort(`WasmTerminal` vs `WasmTerminals`) 부여
- optional 파라미터는 `eps` 대체 케이스를 추가 생성
- 부적절한 인스턴스 axiom은 skip 목록으로 제외

---

## 8. `translate_decd`: 함수 정의를 `op` + `eq/ceq`

핵심 산출물:

- 함수 선언: `op $fname : <arg sorts> -> <ret sort> .`
- 본문 규칙: `eq` 또는 `ceq`

핵심 로직:

- 결과 타입이 bool-ish이면 return sort를 `Bool`로 올바르게 추론
- lhs/rhs/premises에서 변수 집합을 추적
- 전제 스케줄러 결과로 `:=`와 Bool 조건을 분리해서 `if`를 조립
- `[owise]` 전제는 식 끝 옵션으로 반영

---

## 9. `translate_reld`: 일반 relation을 Bool predicate로

핵심 산출물:

- `op rel : ... -> Bool .`
- 각 규칙을 `eq/ceq rel(...) = true [if ...]`로 생성

주의점:

- premise가 Step 계열 relation을 직접 참조하면 skip
  - 이유: Step 계열은 Bool 관계가 아니라 실행 규칙 세계(`step(<...>)`)로 번역되기 때문

---

## 10. `translate_step_reld`: 실행 의미론 전용 규칙 생성

Step 계열(`Step`, `Step-pure`, `Step-read`)은 별도 경로를 탄다.

핵심 산출물:

- `rl/crl [rule-name] : step(< Z | IS >) => < Z' | IS' > [if ...] .`
- context rule이면 heat/cool 규칙 쌍 생성

중요 포인트:

- conclusion을 분해해 `(상태 z, 명령열 instrs)` 형태를 추출
- sequence binder는 `WasmTerminals`로 선언
- val sequence에는 `all-vals(...) = true` guard 추가
- `ListN` 누적 정보로 `N := len(seq)` 조건 추가

---

## 11. 마지막 후처리: 파싱 모호성/선언 충돌 제거

`translate` 끝부분의 post-processing이 하는 일:

1. 선언부/식부 분리 재정렬
   - 선언(op/var/sort)을 위로, 식(eq/ceq/rl/crl)을 아래로
2. 누락된 canonical ctor 선언 보강
3. 모호성 제거
   - 같은 이름의 0-arity ctor와 고차 arity ctor가 공존하면 0-arity 제거
   - 같은 이름이 `var`와 `op`로 겹치면 상수 `op` 제거
4. fallback 변수 선언 자동 생성

왜 필요하나?

- Maude에서 op/var 중복과 parse ambiguity는 경고/오작동으로 직결된다.

---

## 12. 처음 보는 사람용 디버깅 루트

읽다가 막히면 아래 역순으로 보면 빨리 풀립니다.

1. 최종 조립: `translate`
2. 디스패처: `translate_definition`
3. 해당 핸들러 하나만 선택: `translate_typd` 또는 `translate_decd` 또는 `translate_reld/step`
4. 그 핸들러 내부에서 호출하는 `translate_exp`
5. 변수 관련 문제면 `schedule_prems`, `partition_vars` 확인

---

## 13. 최소 체크리스트 (이 6개 답하면 이해한 것)

1. 왜 프리스캔이 필요한가?
2. `texpr.vars`가 없으면 어떤 문제가 생기나?
3. `PremEq`가 `:=`로 승격되는 조건은?
4. `RelD`와 `Step RelD`가 왜 다른 경로를 타나?
5. `ListN`이 왜 전역 accumulator를 쓰나?
6. 후처리에서 0-arity ctor 제거를 왜 하나?

이 6개를 말로 설명할 수 있으면, 변환 로직은 거의 잡은 상태입니다.
