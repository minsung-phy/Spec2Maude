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
  - `ListN`은 별도 suffix 없이 본문 식을 그대로 번역

현재 버전 포인트:

- `ListN` 카운터를 전역 accumulator로 모아 `len(...)` 조건을 자동 주입하지 않는다.
- 대신 바인더 매핑/전제 스케줄러가 rule별 로컬 정보만 사용한다.

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
        return translate_step_reld(name, def.rules)   # step(<...>) eq/ceq 실행식
      else:
        return translate_reld(def.id, name, def.rules) # Judgement membership 관계

    case GramD or HintD:
      return ""
```

### 6.2 syntax 변환 수도코드 (`TypD`) + Maude 결과 모양

처음 보는 분은 아래처럼 읽으면 가장 쉽습니다.

1. 타입 이름/파라미터를 정리한다.
2. 필요한 타입 선언(`sort`, `op`)을 만든다.
3. 각 `inst`를 `VariantT | AliasT | StructT`로 나눠 membership 규칙을 만든다.

여기서 `hasType`는 "값이 어떤 타입을 가진다"를 Maude 식으로 적는 표기이고, `WellTyped`는 그런 타입 판정을 담는 공통 sort입니다.
즉 `T hasType S`는 "T가 S 타입이다"라는 뜻으로 읽으면 됩니다.

```text
function translate_typd(id, params, insts):
  name = sanitize(id)
  type_sort = sort_of_type_name(id)
  is_parametric = (params is not empty)

  # 선언부: 이미 내장/공통 sort면 생략
  emit declarations for type (sort/subsort/op)

  for inst in insts:
    match inst.deftyp:

      case VariantT(cases):
        # 생성자 케이스마다 규칙 생성
        for case in cases:
          lhs = 생성자 좌변을 만듬
          prems = 전제를 정리
          type_term = hasType 뒤에 붙는 타입 식 (예: binop ( Inn ))

          if is_parametric:
            emit (mb|cmb) (lhs hasType(type_term)) : WellTyped [if cond]
          else:
            emit (mb|cmb) lhs : type_sort [if cond]

          if optional params exist and prems is empty:
            emit extra eps-substituted clauses

      case AliasT(typ):
        if is_parametric:
          emit (mb|cmb) (lhs hasType(type_term)) : WellTyped [if cond]
        else:
          emit (mb|cmb) lhs : type_sort [if cond]

      case StructT(fields):
        if is_parametric:
          emit (mb|cmb) ({item(...); ...} hasType(type_term)) : WellTyped [if cond]
        else:
          emit (mb|cmb) {item(...); ...} : type_sort [if cond]
```

아래는 실제로 나오는 Maude 형태 예시입니다.

```maude
--- (1) 타입 선언부 예시
op binop : WasmTerminal -> WasmType [ctor] .

--- (2) VariantT, parametric 예시
cmb ( CTORADDA0 hasType ( binop ( Inn ) ) ) : WellTyped
  if INN : Numtype .

--- (3) VariantT, non-parametric 예시
mb ( CTORADDA0 ) : Binop .

--- (4) optional 인자 eps 확장 예시 (전제 없을 때만)
mb ( CTORFOOA1 ( eps ) ) : Foo .

--- (5) StructT 예시
cmb ( { item('FIELD, ( F-FIELD-0 )) } hasType ( recType ( T ) ) ) : WellTyped
  if F-FIELD-0 : WasmTerminal .
```

요약하면, `translate_typd`는 "타입 정의를 Maude membership 규칙(`mb/cmb`)으로 바꾸는 함수"이고,
파라메트릭이면 `hasType ... : WellTyped`, 아니면 `... : type_sort`를 출력합니다.

정리해서 보면:

- `hasType`: 값과 타입을 연결하는 연산자
- `WellTyped`: `hasType`가 들어가는 판정식을 담는 상위 sort
- `mb/cmb`: "이 식이 이 sort에 속한다"를 선언하는 Maude 문법

### 6.3 def 변환 수도코드 (`DecD`) + Maude 결과 모양

처음 보는 분은 아래 4단계로 보면 쉽습니다.

1. 함수 시그니처를 보고 `op` 선언 1줄을 만든다.
2. 각 본문(`DefD`)을 `lhs = rhs` 형태로 번역한다.
3. 전제(`prems`)를 정리해 `:=` 바인딩과 Bool 조건을 합친다.
4. 조건이 있으면 `ceq`, 없으면 `eq`를 출력한다 (`owise`면 `[owise]` 추가).

```text
function translate_decd(ss, id, params, result_typ, insts):
  fn = 함수 이름(보통 "$" 접두)
  arg_sorts = 인자 sort들
  ret_sort = 함수가 최종 반환할 Maude sort (op 선언의 화살표 오른쪽, 예: Bool / WasmTerminal)

  emit op fn : arg_sorts -> ret_sort

  for inst in insts:
    lhs = 인자 패턴 번역
    rhs = 결과 식 번역

    prems = 전제 스케줄링
      - PremEq   -> 가능하면 X := term
      - PremBool -> Bool 조건

    cond = 바인딩 조건 + Bool 조건 + 바인더 타입 조건

    if cond is empty:
      emit eq  fn(lhs) = rhs
    else:
      emit ceq fn(lhs) = rhs if cond

    if owise 전제가 있으면:
      append [owise]

  emit 필요한 var/op 보조 선언
```

아래는 실제로 나오는 Maude 형태 예시입니다.

```maude
--- (1) 함수 선언
op $f : WasmTerminal WasmTerminal -> WasmTerminal .

--- (2) 전제 없는 본문: eq
eq $f ( X, Y ) = X .

--- (3) 전제 있는 본문: ceq
ceq $f ( X, Y ) = Z
  if Z := g ( X ) /\ ( X == Y ) = true .

--- (4) owise 케이스
ceq $f ( X, Y ) = Y [owise] .
```

핵심은 `translate_decd`가 "함수 정의를 Maude 함수식(`eq/ceq`)"으로 바꾸는 함수라는 점입니다.

### 6.4 rule 변환 수도코드 (`RelD`) + Maude 결과 모양

`RelD`는 두 갈래로 나뉩니다.

- 일반 relation: `Judgement` membership(`mb/cmb`)으로 변환
- Step 계열 relation: 실행식 `step(<...>)`의 `eq/ceq`로 변환

#### (A) 일반 relation (`translate_reld`)

```text
function translate_reld(id, rel_name, rules):
  emit op rel_name : ... -> Judgement [ctor]

  for rule in rules:
    if 전제가 Step 계열 relation을 직접 참조하면:
      skip

    lhs = 결론 패턴 번역
    prems = 전제 스케줄링 (:= 먼저, Bool 나중)
    cond = 전제 조건 + 바인더 타입 조건

    if cond is empty:
      emit mb  rel_name(lhs) : ValidJudgement
    else:
      emit cmb rel_name(lhs) : ValidJudgement if cond
```

```maude
--- 일반 relation 선언
op valid : WasmTerminal -> Judgement [ctor] .

--- 전제 없는 규칙
mb valid ( T ) : ValidJudgement .

--- 전제 있는 규칙
cmb valid ( T ) : ValidJudgement
  if T : WasmTerminal .
```

#### (B) Step 계열 relation (`translate_step_reld`)

```text
function translate_step_reld(rel_name, rules):
  for rule in rules:
    if rule has RulePr premise:
      skip

    결론을 Step/Step-read/Step-pure 모양으로 분해
    lhs/rhs instruction 시퀀스 번역
    prems = 전제 스케줄링
    IS : WasmTerminals continuation 변수 도입

    if cond is empty:
      emit eq  step(<Z | LHS IS>) = <Z' | RHS IS>
    else:
      emit ceq step(<Z | LHS IS>) = <Z' | RHS IS> if cond

  emit 필요한 변수 선언
```

```maude
--- Step 규칙 (무조건)
eq step(< Z | LHS IS >) = < Z' | RHS IS > .

--- Step 규칙 (조건부)
ceq step(< Z | LHS IS >) = < Z' | RHS IS >
  if X := term /\ cond = true .
```

핵심은 일반 relation은 "판정식(`ValidJudgement`)"으로, Step 계열은 "실행식(`step`)"으로 번역된다는 점입니다.

### 6.5 발표용 20초 요약

- `TypD`는 타입 선언과 타입 제약(`mb/cmb`, parametric이면 `hasType` + `WellTyped`)을 만든다.
- `DecD`는 함수 `op` 선언과 함수 식 `eq/ceq`를 만든다.
- `RelD`는 일반 규칙이면 `Judgement -> ValidJudgement` membership(`mb/cmb`), Step 계열이면 `step(<...>)` 식 `eq/ceq`로 만든다.
- 세 경우 모두 premise를 먼저 재배치해 가능한 항목은 `:=` 바인딩으로 승격하고, 나머지는 `if` 조건으로 붙인다.

---

## 7. `translate_typd`: 타입 정의를 sort/member 규칙으로

핵심 산출물:

- `sort` / `subsort`
- 타입 생성자 `op ... : ... -> WasmType [ctor]`
- 멤버십/타입검사 `mb`/`cmb` (`parametric`은 `(T hasType S) : WellTyped`)

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

## 9. `translate_reld`: 일반 relation을 Judgement membership으로

핵심 산출물:

- `op rel : ... -> Judgement [ctor] .`
- 각 규칙을 `mb/cmb rel(...) : ValidJudgement [if ...]`로 생성

주의점:

- premise가 Step 계열 relation을 직접 참조하면 skip
  - 이유: Step 계열은 `step(<...>)` 실행식으로 번역되므로 Judgement membership으로 직접 표현할 수 없음

---

## 10. `translate_step_reld`: 실행 의미론 전용 식(`step`) 생성

Step 계열(`Step`, `Step-pure`, `Step-read`)은 별도 경로를 탄다.

핵심 산출물:

- `eq/ceq step(< Z | LHS IS >) = < Z' | RHS IS > [if ...] .`
- rule 단위 continuation 변수 `IS : WasmTerminals` 선언

중요 포인트:

- `RulePr` premise가 있는 규칙(bridge/context)은 현재 스킵
- conclusion을 relation 종류별(`Step`/`Step-read`/`Step-pure`)로 분해
- 바인더 타입조건 + 전제 스케줄 결과를 `if` 조건으로 결합
- 모든 step 식은 `IS` tail을 보존하는 형태로 생성

---

## 11. 마지막 후처리: 파싱 모호성/선언 충돌 제거

`translate` 끝부분의 post-processing이 하는 일:

1. 선언부/식부 분리 재정렬
  - 선언(op/var/sort)을 위로, 식(eq/ceq/mb/cmb)을 아래로
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
5. 왜 `RulePr` premise가 있는 Step 규칙은 현재 스킵하나?
6. 후처리에서 0-arity ctor 제거를 왜 하나?

이 6개를 말로 설명할 수 있으면, 변환 로직은 거의 잡은 상태입니다.
