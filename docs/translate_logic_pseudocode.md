## 1. 변환 로직 수도코드

```text
function translate_definition(ss, def) : // ss: scan state (pre-scan으로 모은 정보들), def: IL AST의 정의 노드(TypD, DecD, RelD, .. 중 하나)
    match def.kind :
        case RecD :
            return concat(map(child -> translate_definition(ss, child), def.children))
        
        case TypD :
            return translate_typd(def.id, def.params, def.insts)

        case DecD :
            retuen translate_decd(ss, def.id, def.params, def.result_typ, def.insts)
        
        case RelD :
            name = sanatize(def.id)
            if name in {"Step", "Step-pure", "Step-read"} :
                return translate_step_reld(name, def.rules)
            else :
                return translate_reld(def.id, name, def.rules)
        
        case GramD or HintD :
            return ""
```

### 2. syntax 변환 수도코드 (`TypD`) + Maude 결과 모양

1. 타입 이름/파라미터를 정리한다.
2. 필요한 타입 선언(`sort`, `op`)을 만든다.
3. 각 `inst`를 `VariantT | AliasT | StructT`로 나눠 membership 규칙을 만든다.

여기서 `hasType`는 "값이 어떤 타입을 가진다"를 Maude 식으로 적는 표기이고, `WellTyped`는 그런 타입 판정을 담는 공통 sort이다.
즉, `T hasType S`는 "T가 S 타입이다"라는 뜻이다.
maue의 membership eq는 우변에 단 하나의 값만 있어야하기 때문에 이렇게 표현하였다.
> 예시 :
> A는 NumType -> mb A : NumType .
> ADD는 [i32, i32] -> [i32] 타입 -> mb Add : (I32 I32 -> I32) . 
>> mb의 우변은 띄어쓰기나 기호가 없는 단어 딱 1개(sort 이름)이 와야함 -> 따라서 Syntax Error
>> 그래서 mb (Add hasType (I32 I32 -> I32)) : WellTyped . 라고 해야함 

```text
function translate_typd(id, params, insts) :
    name = sanitize(id)
    type_sort = sort_of_type_name(id)
    is_parametric = (params is not empty)

    // 선언부: 이미 내장/공통 sort면 생략
    emit declarations for type (sort/subsort/op)

    for inst in insts :
        match inst.deftype :
            case VariantT(cases) :
                for case in cases :
                    lhs = 생성자 좌변을 만듬
                    prems = 전제를 정리함
                    type_term = hasType 뒤에 붙는 타입 식 (예: binop(Inn))

                    if is_parametric :
                        emit (mb|cmb) (lhs hasType(type_term)) : WellTyped [if cond]
                    else :
                        emit (mb|cmb) lhs : type_sort [if cond]
                    
                    if optional params exist and prems is empty :
                        emit extra eps-substituted clauses
                
            case AliasT(typ) :
                if is_parametric :
                    emit (mb|cmb) (lhs hasType(type_term)) : WellTyped [if cond]
                else :
                    emit (mb|cmb) lhs : type_sort [if cond]
            
            case StructT(fields) :
                if is_parametric :
                    emit (mb|cmb) ({item(...); ...} hasType(type_term)) : WellTyped [if cond]
                else :
                    emit (mb|cmb) {item(...); ...} : type_sort [if cond]
```

아래는 실제로 나오는 Maude 형태 예시이다.

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

### 3. def 변환 수도코드 (`DecD`) + Maude 결과 모양

1. 함수 시그니처를 보고 `op` 선언 1줄을 만든다.
2. 각 본문(`DefD`)을 `lhs = rhs` 형태로 번역한다.
3. 전제(`prems`)를 정리해 `:=` 바인딩과 Bool 조건을 합친다.
4. 조건이 있으면 `ceq`, 없으면 `eq`를 출력한다 (`owise`면 `[owise]` 추가).

```text
function translate_decd(ss, id, params, result_typ, insts) :
    fn = 함수 이름
    arg_sorts = 인자 sort들
    ret_sort = 함수가 최종 반환할 Maude sort (op 선언의 화살표 오른쪽, 예: Bool or WasmTerminal)

    emit op fn : arg_sorts -> ret_sort

    for inst in insts :
        lhs = 인자 패턴 변환
        rhs = 결과 식 변환
        prems = 전제를 정리함
        
        cond = 바인딩 조건 + Bool 조건 + 바인더 타입 조건

        if cond is empty :
            emit eq  fn(lhs) = rhs
        else :
            emit ceq fn(lhs) = rhs if cond
        
        if owise 전제가 있으면 :
            append [owise]

    emit 필요한 var/op 보조 선언
```

아래는 실제로 나오는 Maude 형태 예시이다.

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

### 4. rule 변환 수도코드 (`RelD`) + Maude 결과 모양

`RelD`는 두 갈래로 나뉜다.

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