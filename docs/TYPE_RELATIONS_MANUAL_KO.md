# 실행 premise에 필요한 타입 relation — 원문·의미·Maude 전체 초안

현재 working tree의 SpecTec 원문과 실제 IL AST를 기준으로, `Expand`, `Ref_ok`, `Val_ok`, `Module_ok`, `Externaddr_ok`에서 시작하여 **RulePr 의존성을 재귀적으로 따라간 전체 77개 relation·283개 활성 rule**을 싣는다. 각 rule은 **SpecTec 원문 → 의미 → Maude 식** 순서다. 전체 relation을 원문 그대로 보존하는 범위이며, 이미 검증된 입력을 전제로 일부 검사를 생략하는 설계의 최소 개수라는 뜻은 아니다.

**상태: rule별 번역식 초안이다. 실행 가능한 전체 Bool 판정기 또는 기존 backend의 완성된 대체 구현은 아니다.** 274개 rule에는 직접 조건/출력 식을 적었다. 9개 rule에는 중간 타입·local 초기화 정보·문맥을 추가로 받은 검사식을 적었다. 그 중간 값을 찾아 원래 relation 호출에 연결하는 계산은 아직 완성하지 않았다. 실패 판단에 `false [owise]`를 임의 추가하지 않았다.

아래 식의 대상은 해당 source syntax를 만족하는 유한 ground 값이다. source 타입 descriptor를 검사하는 `typecheck`와 Wasm typing/subtyping relation은 역할이 다르다. Maude generic carrier에 어떤 항이나 넣어도 원문의 judgment를 판정한다는 주장은 하지 않는다.

## 읽기 전에 필요한 말

- **참조 값**: 함수·struct·array 같은 대상을 가리키거나 i31 값을 나타내는 Wasm 값. `REF.NULL_ADDR`, `REF.I31_NUM 7`, `REF.STRUCT_ADDR 0` 등이 값이다.
- **참조 타입**: 어떤 참조 값을 받을 수 있는지 적은 타입. `REF I31`, `REF NULL ANY` 등이 타입 표현이다.
- `REF(eps, I31)`: null을 허용하지 않는 i31 참조 타입. `REF(NULL ?, BOT)`: null은 허용하지만 non-null 대상은 없는 참조 타입.
- Maude의 `NULL ?`는 **NULL 표시 하나가 들어 있는 option 값**이다. SpecTec의 `NULL?`처럼 “있을 수도 없을 수도 있음”을 나타내는 패턴과 구분한다. 그 패턴의 두 경우는 `eps`와 `NULL ?`다.
- `s`는 실행 store, `C`는 검증 문맥이다. source의 `{}` 문맥은 elaboration에서 기본 필드 13개를 채운 record가 된다. 여기서는 이를 `empty-context`로 적었다.
- `*`는 리스트, `?`는 없거나 하나, `^n`은 n개. 리스트가 다른 값의 한 원소로 들어갈 때 Maude의 `seq(...)`로 감싼다.
- `:=`는 계산한 값을 왼쪽 패턴에 맞추어 변수를 얻는 matching condition이다. `==`는 이미 주어진 두 값을 비교한다.
- Maude `op` 선언의 `~>`는 결과 sort 소속을 보장하지 않는 부분 연산 선언이다. SpecTec 실행 화살표와 별개다. 여기서 미계산은 `false`로 간주하지 않는다.
- `X:Nat`, `C:SpectecTerminal`은 Maude inline 변수 선언이다. 식을 독립적으로 읽고 load할 수 있게 각 변수의 sort를 함께 적었다.

## 다섯 직접 사용 relation과 포함 범위

| 시작 relation | 하는 일 |
|---|---|
| `Expand` | 정의 타입을 펼쳐 함수·struct·array의 실제 구성 타입을 꺼낸다. |
| `Ref_ok` | store 안의 참조 값이 요청한 참조 타입으로 사용될 수 있는지 판단한다. |
| `Val_ok` | 숫자·벡터·참조 값 각각을 요청 타입으로 사용할 수 있는지 판단한다. |
| `Module_ok` | 모듈의 모든 정의와 본문을 검증하면서 import/export 타입을 구한다. |
| `Externaddr_ok` | 연결한 함수·메모리·테이블·전역 변수·태그의 실제 타입이 요구한 타입에 맞는지 판단한다. |

`Module_ok`의 원문을 전부 구현하면 `Func_ok → Expr_ok → Instrs_ok → Instr_ok`도 따라온다. 따라서 함수 본문의 명령어 타입 검사까지 이 문서에 포함된다. 이것이 현재 수동 Module-ok의 “검증된 모듈에서 타입만 계산”하는 계약보다 넓은 이유다.

활성 rule의 수는 실제 Il.Ast에서 계산했다. source의 주석 `( ; ... ; )`에 있는 예전 `Instr_ok/load`, `Instr_ok/store` 두 rule은 제외했다. 실제 원문 구분자는 공백 없이 `(;`, `;)`다. 활성 load/store 변형은 포함했다. 텍스트 검색만 하면 285개로 잘못 셀 수 있다.

## 아직 완성되지 않은 아홉 rule

| Rule | 현재 적은 Maude 식 | 원래 호출로 연결하려면 필요한 것 |
|---|---|---|
| `Heaptype_sub/trans` | `Heaptype-sub-via-trans(C,H1,H2,MID)` | 중간 heaptype를 찾는 완전한 계산 |
| `Instrs_ok/seq` | 중간 stack 타입을 받은 검사 | 첫 명령어의 중간 stack 타입 유도 |
| `Instrs_ok/sub` | 이전 instruction type을 받은 검사 | 이전 instruction type의 유도 |
| `Instr_ok/select-impl` | 상위 숫자/벡터 타입을 받은 검사 | 조건을 만족하는 상위 타입 선택 |
| `Instr_ok/block`, `/loop` | 본문 local 초기화 리스트를 받은 검사 | 본문의 초기화 결과 유도 |
| `Instr_ok/if` | 두 분기의 초기화 리스트를 받은 검사 | 각 분기의 초기화 결과 유도 |
| `Instr_ok/try_table` | 본문 초기화 리스트를 받은 검사 | 본문의 초기화 결과 유도 |
| `Module_ok` | 문맥과 각 타입 리스트를 받은 전체 조건 검사 | 원문 조건을 만족하는 문맥·타입 리스트 구성 |

이 검사식 하나가 실패해도 원래 relation이 거짓이라는 뜻은 아니다. 다른 중간 값으로 성공할 수 있기 때문이다. 따라서 아래 `-via-` 식에 무조건 `false [owise]`를 붙여 원래 relation의 거부 판정으로 사용하지 않는다.

## 전체 relation 인덱스

| 번호 | Relation | 활성 rule 수 | 직접 premise에서 사용하는 relation |
|---:|---|---:|---|
| 1 | [Expand](#expand) | 1 |  |
| 2 | [Ref_ok](#ref-ok) | 9 | `Ref_ok`, `Reftype_ok`, `Reftype_sub` |
| 3 | [Val_ok](#val-ok) | 3 | `Num_ok`, `Ref_ok`, `Vec_ok` |
| 4 | [Module_ok](#module-ok) | 1 | `Data_ok`, `Elem_ok`, `Export_ok`, `Func_ok`, `Globals_ok`, `Import_ok`, `Mem_ok`, `Start_ok`, `Table_ok`, `Tag_ok`, `Types_ok` |
| 5 | [Externaddr_ok](#externaddr-ok) | 6 | `Externaddr_ok`, `Externtype_ok`, `Externtype_sub` |
| 6 | [Reftype_ok](#reftype-ok) | 1 | `Heaptype_ok` |
| 7 | [Reftype_sub](#reftype-sub) | 2 | `Heaptype_sub` |
| 8 | [Num_ok](#num-ok) | 1 |  |
| 9 | [Vec_ok](#vec-ok) | 1 |  |
| 10 | [Data_ok](#data-ok) | 1 | `Datamode_ok` |
| 11 | [Elem_ok](#elem-ok) | 1 | `Elemmode_ok`, `Expr_ok_const`, `Reftype_ok` |
| 12 | [Export_ok](#export-ok) | 1 | `Externidx_ok` |
| 13 | [Func_ok](#func-ok) | 1 | `Expand`, `Expr_ok`, `Local_ok` |
| 14 | [Globals_ok](#globals-ok) | 2 | `Global_ok`, `Globals_ok` |
| 15 | [Import_ok](#import-ok) | 1 | `Externtype_ok` |
| 16 | [Mem_ok](#mem-ok) | 1 | `Memtype_ok` |
| 17 | [Start_ok](#start-ok) | 1 | `Expand` |
| 18 | [Table_ok](#table-ok) | 1 | `Expr_ok_const`, `Tabletype_ok` |
| 19 | [Tag_ok](#tag-ok) | 1 | `Tagtype_ok` |
| 20 | [Types_ok](#types-ok) | 2 | `Type_ok`, `Types_ok` |
| 21 | [Externtype_ok](#externtype-ok) | 5 | `Expand_use`, `Globaltype_ok`, `Memtype_ok`, `Tabletype_ok`, `Tagtype_ok`, `Typeuse_ok` |
| 22 | [Externtype_sub](#externtype-sub) | 5 | `Deftype_sub`, `Globaltype_sub`, `Memtype_sub`, `Tabletype_sub`, `Tagtype_sub` |
| 23 | [Heaptype_ok](#heaptype-ok) | 3 | `Typeuse_ok` |
| 24 | [Heaptype_sub](#heaptype-sub) | 21 | `Deftype_sub`, `Expand`, `Heaptype_ok`, `Heaptype_sub` |
| 25 | [Datamode_ok](#datamode-ok) | 2 | `Expr_ok_const` |
| 26 | [Elemmode_ok](#elemmode-ok) | 3 | `Expr_ok_const`, `Reftype_sub` |
| 27 | [Expr_ok_const](#expr-ok-const) | 1 | `Expr_const`, `Expr_ok` |
| 28 | [Externidx_ok](#externidx-ok) | 5 |  |
| 29 | [Expr_ok](#expr-ok) | 1 | `Instrs_ok` |
| 30 | [Local_ok](#local-ok) | 2 | `Defaultable`, `Nondefaultable` |
| 31 | [Global_ok](#global-ok) | 1 | `Expr_ok_const`, `Globaltype_ok` |
| 32 | [Memtype_ok](#memtype-ok) | 1 | `Limits_ok` |
| 33 | [Tabletype_ok](#tabletype-ok) | 1 | `Limits_ok`, `Reftype_ok` |
| 34 | [Tagtype_ok](#tagtype-ok) | 1 | `Expand_use`, `Typeuse_ok` |
| 35 | [Type_ok](#type-ok) | 1 | `Rectype_ok` |
| 36 | [Expand_use](#expand-use) | 2 | `Expand` |
| 37 | [Globaltype_ok](#globaltype-ok) | 1 | `Valtype_ok` |
| 38 | [Typeuse_ok](#typeuse-ok) | 3 | `Deftype_ok` |
| 39 | [Deftype_sub](#deftype-sub) | 2 | `Heaptype_sub` |
| 40 | [Globaltype_sub](#globaltype-sub) | 2 | `Valtype_sub` |
| 41 | [Memtype_sub](#memtype-sub) | 1 | `Limits_sub` |
| 42 | [Tabletype_sub](#tabletype-sub) | 1 | `Limits_sub`, `Reftype_sub` |
| 43 | [Tagtype_sub](#tagtype-sub) | 1 | `Deftype_sub` |
| 44 | [Expr_const](#expr-const) | 1 | `Instr_const` |
| 45 | [Instrs_ok](#instrs-ok) | 4 | `Instr_ok`, `Instrs_ok`, `Instrtype_ok`, `Instrtype_sub`, `Resulttype_ok` |
| 46 | [Defaultable](#defaultable) | 1 |  |
| 47 | [Nondefaultable](#nondefaultable) | 1 |  |
| 48 | [Limits_ok](#limits-ok) | 1 |  |
| 49 | [Rectype_ok](#rectype-ok) | 2 | `Rectype_ok`, `Subtype_ok` |
| 50 | [Valtype_ok](#valtype-ok) | 4 | `Numtype_ok`, `Reftype_ok`, `Vectype_ok` |
| 51 | [Deftype_ok](#deftype-ok) | 1 | `Rectype_ok2` |
| 52 | [Valtype_sub](#valtype-sub) | 4 | `Numtype_sub`, `Reftype_sub`, `Vectype_sub` |
| 53 | [Limits_sub](#limits-sub) | 2 |  |
| 54 | [Instr_const](#instr-const) | 14 |  |
| 55 | [Instr_ok](#instr-ok) | 110 | `Blocktype_ok`, `Catch_ok`, `Defaultable`, `Expand`, `Heaptype_ok`, `Instrs_ok`, `Instrtype_ok`, `Memarg_ok`, `Reftype_ok`, `Reftype_sub`, `Resulttype_sub`, `Storagetype_sub`, `Valtype_ok`, `Valtype_sub` |
| 56 | [Instrtype_ok](#instrtype-ok) | 1 | `Resulttype_ok` |
| 57 | [Instrtype_sub](#instrtype-sub) | 1 | `Resulttype_sub` |
| 58 | [Resulttype_ok](#resulttype-ok) | 1 | `Valtype_ok` |
| 59 | [Subtype_ok](#subtype-ok) | 1 | `Comptype_ok`, `Comptype_sub` |
| 60 | [Numtype_ok](#numtype-ok) | 1 |  |
| 61 | [Vectype_ok](#vectype-ok) | 1 |  |
| 62 | [Rectype_ok2](#rectype-ok2) | 2 | `Rectype_ok2`, `Subtype_ok2` |
| 63 | [Numtype_sub](#numtype-sub) | 1 |  |
| 64 | [Vectype_sub](#vectype-sub) | 1 |  |
| 65 | [Blocktype_ok](#blocktype-ok) | 2 | `Expand`, `Valtype_ok` |
| 66 | [Catch_ok](#catch-ok) | 4 | `Expand`, `Resulttype_sub` |
| 67 | [Memarg_ok](#memarg-ok) | 1 |  |
| 68 | [Resulttype_sub](#resulttype-sub) | 1 | `Valtype_sub` |
| 69 | [Storagetype_sub](#storagetype-sub) | 2 | `Packtype_sub`, `Valtype_sub` |
| 70 | [Comptype_ok](#comptype-ok) | 3 | `Fieldtype_ok`, `Resulttype_ok` |
| 71 | [Comptype_sub](#comptype-sub) | 3 | `Fieldtype_sub`, `Resulttype_sub` |
| 72 | [Subtype_ok2](#subtype-ok2) | 1 | `Comptype_ok`, `Comptype_sub`, `Typeuse_ok` |
| 73 | [Packtype_sub](#packtype-sub) | 1 |  |
| 74 | [Fieldtype_ok](#fieldtype-ok) | 1 | `Storagetype_ok` |
| 75 | [Fieldtype_sub](#fieldtype-sub) | 2 | `Storagetype_sub` |
| 76 | [Storagetype_ok](#storagetype-ok) | 2 | `Packtype_ok`, `Valtype_ok` |
| 77 | [Packtype_ok](#packtype-ok) | 1 |  |


<a id="expand"></a>

## 1. `Expand`

정의 타입을 펼쳐 함수·struct·array의 실제 구성 타입을 꺼낸다.

**SpecTec 선언**


```spectec
relation Expand: deftype ~~ comptype hint(macro "%expanddt") hint(tabular) hint(maude_eq)
```

**Maude 선언**


```maude
op Expand : SpectecTerminal ~> SpectecTerminal .
```


### 1.1. `Expand`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:78)

**SpecTec**


```spectec
rule Expand: deftype ~~ comptype   -- if $unrolldt(deftype) = SUB final? typeuse* comptype
```

**의미**

정의 타입을 펼쳐 함수·struct·array의 실제 구성 타입을 꺼낸다.

**Maude — 번역식 초안**


```maude
ceq Expand(DEFTYPE:SpectecTerminal) = COMPTYPE:SpectecTerminal
  if SUB(FINAL-:SpectecTerminals, TYPEUSE-:SpectecTerminals, COMPTYPE:SpectecTerminal) := unrolldt(DEFTYPE:SpectecTerminal)
    /\ len(FINAL-:SpectecTerminals) <= 1 .
```


<a id="ref-ok"></a>

## 2. `Ref_ok`

store 안의 참조 값이 요청한 참조 타입으로 사용될 수 있는지 판단한다.

**SpecTec 선언**


```spectec
relation Ref_ok: store |- ref : reftype  hint(macro "%ref") hint(maude_backend "check")
```

**Maude 선언**


```maude
op Ref-ok : SpectecTerminal val SpectecTerminal ~> Bool .
```

위 `Ref-ok`는 요청 타입을 검사하는 공개 호출이다. 아래 보조 `ref-ok`는 기본 타입을 구하고 `ref-ok-sub`는 요청 타입을 검사한다. 이 두 보조 함수의 선언은 공통 코드 부록에 있다.


### 2.1. `Ref_ok/null`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:35)

**SpecTec**


```spectec
rule Ref_ok/null:
  s |- REF.NULL_ADDR : REF NULL BOT
```

**의미**

null 값 REF.NULL_ADDR의 기본 참조 타입은 REF NULL BOT이다. NULL은 null 허용, BOT는 null이 아닌 대상 종류가 없음을 뜻한다.

**Maude — 번역식 초안**


```maude
eq ref-ok(S:SpectecTerminal, REF.NULL-ADDR) = REF(NULL ?, BOT) .
```


### 2.2. `Ref_ok/i31`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:38)

**SpecTec**


```spectec
rule Ref_ok/i31:
  s |- REF.I31_NUM i : REF I31
```

**의미**

REF.I31_NUM i 전체가 i31 참조 값이다. 그 기본 타입은 null을 허용하지 않는 REF I31이다. payload i 자체를 참조라고 부르는 것은 아니다.

**Maude — 번역식 초안**


```maude
eq ref-ok(S:SpectecTerminal, REF.I31-NUM(I:Nat)) = REF(eps, I31) .
```


### 2.3. `Ref_ok/struct`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:41)

**SpecTec**


```spectec
rule Ref_ok/struct:
  s |- REF.STRUCT_ADDR a : REF dt
  -- if s.STRUCTS[a].TYPE = dt
```

**의미**

store의 STRUCTS[a]를 찾아 TYPE dt를 읽는다. 주소 a의 struct를 가리키는 참조를 REF dt 타입으로 인정한다.

**Maude — 번역식 초안**


```maude
ceq ref-ok(S:SpectecTerminal, REF.STRUCT-ADDR(A:Nat)) = REF(eps, DT:SpectecTerminal)
  if indexDefined(S:SpectecTerminal . 'STRUCTS, A:Nat)
    /\ INST:SpectecTerminal := (S:SpectecTerminal . 'STRUCTS)[A:Nat]
    /\ DT:SpectecTerminal := INST:SpectecTerminal . 'TYPE .
```


### 2.4. `Ref_ok/array`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:45)

**SpecTec**


```spectec
rule Ref_ok/array:
  s |- REF.ARRAY_ADDR a : REF dt
  -- if s.ARRAYS[a].TYPE = dt
```

**의미**

store의 ARRAYS[a]에 저장된 array의 TYPE dt를 읽어 REF dt 타입으로 인정한다.

**Maude — 번역식 초안**


```maude
ceq ref-ok(S:SpectecTerminal, REF.ARRAY-ADDR(A:Nat)) = REF(eps, DT:SpectecTerminal)
  if indexDefined(S:SpectecTerminal . 'ARRAYS, A:Nat)
    /\ INST:SpectecTerminal := (S:SpectecTerminal . 'ARRAYS)[A:Nat]
    /\ DT:SpectecTerminal := INST:SpectecTerminal . 'TYPE .
```


### 2.5. `Ref_ok/func`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:49)

**SpecTec**


```spectec
rule Ref_ok/func:
  s |- REF.FUNC_ADDR a : REF dt
  -- if s.FUNCS[a].TYPE = dt
```

**의미**

store의 FUNCS[a]에 저장된 함수의 TYPE dt를 읽어 REF dt 타입으로 인정한다.

**Maude — 번역식 초안**


```maude
ceq ref-ok(S:SpectecTerminal, REF.FUNC-ADDR(A:Nat)) = REF(eps, DT:SpectecTerminal)
  if indexDefined(S:SpectecTerminal . 'FUNCS, A:Nat)
    /\ INST:SpectecTerminal := (S:SpectecTerminal . 'FUNCS)[A:Nat]
    /\ DT:SpectecTerminal := INST:SpectecTerminal . 'TYPE .
```


### 2.6. `Ref_ok/exn`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:53)

**SpecTec**


```spectec
rule Ref_ok/exn:
  s |- REF.EXN_ADDR a : REF EXN
  -- if s.EXNS[a] = exn
```

**의미**

EXNS[a]가 exninst 형태의 예외 객체이면 그 주소 참조의 기본 타입은 REF EXN이다. 원문의 객체 바인딩과 타입 조건을 유지한다.

**Maude — 번역식 초안**


```maude
ceq ref-ok(S:SpectecTerminal, REF.EXN-ADDR(A:Nat)) = REF(eps, EXN)
  if indexDefined(S:SpectecTerminal . 'EXNS, A:Nat)
    /\ E:SpectecTerminal := (S:SpectecTerminal . 'EXNS)[A:Nat]
    /\ typecheck(E:SpectecTerminal, exninst) .
```


### 2.7. `Ref_ok/host`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:57)

**SpecTec**


```spectec
rule Ref_ok/host:
  s |- REF.HOST_ADDR a : REF ANY
```

**의미**

host 주소 참조를 null이 아닌 REF ANY 타입으로 인정한다. 원문에는 추가 store 조회 조건이 없다.

**Maude — 번역식 초안**


```maude
eq ref-ok(S:SpectecTerminal, REF.HOST-ADDR(A:Nat)) = REF(eps, ANY) .
```


### 2.8. `Ref_ok/extern`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:60)

**SpecTec**


```spectec
rule Ref_ok/extern:
  s |- REF.EXTERN ref : REF EXTERN
  -- Ref_ok: s |- ref : REF ANY
  -- if ref =/= REF.NULL_ADDR
```

**의미**

감싼 내부 참조가 REF ANY로 인정되고 null이 아니면 전체 REF.EXTERN ref를 REF EXTERN으로 인정한다. 내부 Ref_ok를 먼저 검사한다.

이 rule이 직접 호출하는 relation: `Ref_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq ref-ok(S:SpectecTerminal, REF.EXTERN(R:val)) = REF(eps, EXTERN)
  if ref-ok-sub(S:SpectecTerminal, R:val, REF(eps, ANY))
    /\ R:val =/= REF.NULL-ADDR .
```


### 2.9. `Ref_ok/sub`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:65)

**SpecTec**


```spectec
rule Ref_ok/sub:
  s |- ref : rt
  -- Ref_ok: s |- ref : rt'
  -- Reftype_ok: {} |- rt : OK
  -- Reftype_sub: {} |- rt' <: rt
```

**의미**

이미 인정된 참조 타입 rt'가 있고 요청한 rt가 올바르며 rt' <: rt이면 같은 값을 rt로도 인정한다. 예를 들어 REF I31을 REF ANY로 사용할 수 있다.

이 rule이 직접 호출하는 relation: `Ref_ok`, `Reftype_ok`, `Reftype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**

앞의 기본 rule로 직접 인정하는 경우와 subtype으로 추가 인정하는 경우를 함께 적었다. 기본 타입 계산으로 반복되는 subtype 인정을 묶는 구조이므로, 기본 타입의 유일성과 subtype 연결에 대한 별도 보존 논증이 필요하다. 이 문서의 load/smoke 검사는 그 증명이 아니다.


```maude
--- 앞의 기본 rule이 직접 인정하는 타입은 바로 성공한다.
ceq ref-ok-sub(S:SpectecTerminal, R:val, RT:SpectecTerminal) = true
  if RT:SpectecTerminal := ref-ok(S:SpectecTerminal, R:val) .
--- 기본 타입보다 넓은 타입으로 인정하는 경우.
ceq ref-ok-sub(S:SpectecTerminal, R:val, RT:SpectecTerminal) = true
  if ACTUAL:SpectecTerminal := ref-ok(S:SpectecTerminal, R:val)
    /\ Reftype-ok(empty-context, RT:SpectecTerminal)
    /\ Reftype-sub(empty-context, ACTUAL:SpectecTerminal, RT:SpectecTerminal) .
--- 실행 rule과 Val-ok의 호출 이름을 유지한다.
eq Ref-ok(S:SpectecTerminal, R:val, RT:SpectecTerminal) = ref-ok-sub(S:SpectecTerminal, R:val, RT:SpectecTerminal) .
```


<a id="val-ok"></a>

## 3. `Val_ok`

숫자·벡터·참조 값 각각을 요청 타입으로 사용할 수 있는지 판단한다.

**SpecTec 선언**


```spectec
relation Val_ok: store |- val : valtype  hint(macro "%val") hint(maude_predicate)
```

**Maude 선언**


```maude
op Val-ok : SpectecTerminal val SpectecTerminal ~> Bool .
```


### 3.1. `Val_ok/num`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:72)

**SpecTec**


```spectec
rule Val_ok/num:
  s |- num : nt
  -- Num_ok: s |- num : nt
```

**의미**

숫자·벡터·참조 값 각각을 요청 타입으로 사용할 수 있는지 판단한다.

이 rule이 직접 호출하는 relation: `Num_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Val-ok(S2:SpectecTerminal, NUM:val, NT:SpectecTerminal) = true
  if typecheck(NUM:val, num)
    /\ typecheck(NT:SpectecTerminal, numtype)
    /\ Num-ok(S2:SpectecTerminal, NUM:val, NT:SpectecTerminal) .
```


### 3.2. `Val_ok/vec`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:76)

**SpecTec**


```spectec
rule Val_ok/vec:
  s |- vec : vt
  -- Vec_ok: s |- vec : vt
```

**의미**

숫자·벡터·참조 값 각각을 요청 타입으로 사용할 수 있는지 판단한다.

이 rule이 직접 호출하는 relation: `Vec_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Val-ok(S2:SpectecTerminal, VEC:val, VT:SpectecTerminal) = true
  if typecheck(VEC:val, vec)
    /\ typecheck(VT:SpectecTerminal, vectype)
    /\ Vec-ok(S2:SpectecTerminal, VEC:val, VT:SpectecTerminal) .
```


### 3.3. `Val_ok/ref`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:80)

**SpecTec**


```spectec
rule Val_ok/ref:
  s |- ref : rt
  -- Ref_ok: s |- ref : rt
```

**의미**

숫자·벡터·참조 값 각각을 요청 타입으로 사용할 수 있는지 판단한다.

이 rule이 직접 호출하는 relation: `Ref_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Val-ok(S2:SpectecTerminal, REF2:val, RT:SpectecTerminal) = true
  if typecheck(REF2:val, ref)
    /\ typecheck(RT:SpectecTerminal, reftype)
    /\ Ref-ok(S2:SpectecTerminal, REF2:val, RT:SpectecTerminal) .
```


<a id="module-ok"></a>

## 4. `Module_ok`

모듈의 모든 정의와 본문을 검증하면서 import/export 타입을 구한다.

**SpecTec 선언**


```spectec
relation Module_ok: |- module : moduletype            hint(name "T-module")  hint(macro "%module") hint(maude_backend "compute")
```

**Maude 선언**


```maude
op Module-ok : SpectecTerminal ~> SpectecTerminal .
```

현재 적은 `Module-ok-via-rule`은 source의 중간 값들을 인자로 받는다. `Module-ok(module)`가 그 인자들을 스스로 구성하는 구현은 아직 없다. 이것을 기존 수동 Module-ok와 같은 완성된 출력 함수라고 부르면 안 된다.


### 4.1. `Module_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:144)

**SpecTec**


```spectec
rule Module_ok:
  |- MODULE type* import* tag* global* mem* table* func* data* elem* start? export* : $clos_moduletype(C, xt_I* -> xt_E*)
  -- Types_ok: {} |- type* : dt'*
  -- (Import_ok: {TYPES dt'*} |- import : xt_I)*
  ----
  -- (Tag_ok: C' |- tag : jt)*
  -- Globals_ok: C' |- global* : gt*
  -- (Mem_ok: C' |- mem : mt)*
  -- (Table_ok: C' |- table : tt)*
  -- (Func_ok: C |- func : dt)*
  ----
  -- (Data_ok: C |- data : ok)*
  -- (Elem_ok: C |- elem : rt)*
  -- (Start_ok: C |- start : OK)?
  -- (Export_ok: C |- export : nm xt_E)*
  -- if $disjoint_(name, nm*)
  ----
  -- if C = C' ++ {TAGS jt_I* jt*, GLOBALS gt*, MEMS mt_I* mt*, TABLES tt_I* tt*, DATAS ok*, ELEMS rt*}
  ----
  -- if C' = {TYPES dt'*, GLOBALS gt_I*, FUNCS dt_I* dt*, REFS x*}
  -- if x* = $funcidx_nonfuncs(global* mem* table* elem* start? export*)
  ----
  -- if jt_I* = $tagsxt(xt_I*)
  -- if gt_I* = $globalsxt(xt_I*)
  -- if mt_I* = $memsxt(xt_I*)
  -- if tt_I* = $tablesxt(xt_I*)
  -- if dt_I* = $funcsxt(xt_I*)
```

**의미**

모듈의 모든 정의와 본문을 검증하면서 import/export 타입을 구한다.

이 rule이 직접 호출하는 relation: `Data_ok`, `Elem_ok`, `Export_ok`, `Func_ok`, `Globals_ok`, `Import_ok`, `Mem_ok`, `Start_ok`, `Table_ok`, `Tag_ok`, `Types_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 추가 입력을 받은 조건 검사식. 원래 호출에 대한 완성된 판정기는 아님.**

아래의 긴 인자들은 원문 Q의 중간 변수들이다. 인자들을 모두 주었다는 전제하에 각 premise를 검사한다. 실행 초기화에서 이 인자들이 원래부터 주어지는 것은 아니다.


```maude
op Module-ok-via-rule : SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminal SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminal SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminals SpectecTerminal ~> SpectecTerminal .

ceq Module-ok-via-rule(TYPE-:SpectecTerminals, IMPORT-:SpectecTerminals, TAG-:SpectecTerminals, GLOBAL-:SpectecTerminals, MEM-:SpectecTerminals, TABLE-:SpectecTerminals, FUNC-:SpectecTerminals, DATA-:SpectecTerminals, ELEM-:SpectecTerminals, START-:SpectecTerminals, EXPORT-:SpectecTerminals, C:SpectecTerminal, XT-I-:SpectecTerminals, XT-E-:SpectecTerminals, DT--:SpectecTerminals, C-:SpectecTerminal, JT-:SpectecTerminals, GT-:SpectecTerminals, MT-:SpectecTerminals, TT-:SpectecTerminals, DT-:SpectecTerminals, OK-:SpectecTerminals, RT-3:SpectecTerminals, NM-:SpectecTerminals, JT-I-:SpectecTerminals, MT-I-:SpectecTerminals, TT-I-:SpectecTerminals, GT-I-:SpectecTerminals, DT-I-:SpectecTerminals, X-2:SpectecTerminals, MODULE(TYPE-:SpectecTerminals, IMPORT-:SpectecTerminals, TAG-:SpectecTerminals, GLOBAL-:SpectecTerminals, MEM-:SpectecTerminals, TABLE-:SpectecTerminals, FUNC-:SpectecTerminals, DATA-:SpectecTerminals, ELEM-:SpectecTerminals, START-:SpectecTerminals, EXPORT-:SpectecTerminals)) = clos-moduletype(C:SpectecTerminal, XT-I-:SpectecTerminals -> XT-E-:SpectecTerminals)
  if len(START-:SpectecTerminals) <= 1
    /\ DT--:SpectecTerminals = Types-ok({ (field('TYPES, eps) ; (field('TAGS, eps) ; (field('GLOBALS, eps) ; (field('MEMS, eps) ; (field('TABLES, eps) ; (field('FUNCS, eps) ; (field('DATAS, eps) ; (field('ELEMS, eps) ; (field('LOCALS, eps) ; (field('LABELS, eps) ; (field('RETURN, eps) ; (field('REFS, eps) ; field('RECS, eps))))))))))))) }, TYPE-:SpectecTerminals)
    /\ iterpr-25(DT--:SpectecTerminals, IMPORT-:SpectecTerminals, XT-I-:SpectecTerminals)
    /\ iterpr-26(C-:SpectecTerminal, JT-:SpectecTerminals, TAG-:SpectecTerminals)
    /\ GT-:SpectecTerminals = Globals-ok(C-:SpectecTerminal, GLOBAL-:SpectecTerminals)
    /\ iterpr-27(C-:SpectecTerminal, MEM-:SpectecTerminals, MT-:SpectecTerminals)
    /\ iterpr-28(C-:SpectecTerminal, TABLE-:SpectecTerminals, TT-:SpectecTerminals)
    /\ iterpr-29(C:SpectecTerminal, DT-:SpectecTerminals, FUNC-:SpectecTerminals)
    /\ iterpr-30(C:SpectecTerminal, DATA-:SpectecTerminals, OK-:SpectecTerminals)
    /\ iterpr-31(C:SpectecTerminal, ELEM-:SpectecTerminals, RT-3:SpectecTerminals)
    /\ iterpr-32(C:SpectecTerminal, START-:SpectecTerminals)
    /\ iterpr-33(C:SpectecTerminal, EXPORT-:SpectecTerminals, NM-:SpectecTerminals, XT-E-:SpectecTerminals)
    /\ disjoint-(name, NM-:SpectecTerminals)
    /\ C:SpectecTerminal == recordConcat(C-:SpectecTerminal, { (field('TYPES, eps) ; (field('TAGS, JT-I-:SpectecTerminals JT-:SpectecTerminals) ; (field('GLOBALS, GT-:SpectecTerminals) ; (field('MEMS, MT-I-:SpectecTerminals MT-:SpectecTerminals) ; (field('TABLES, TT-I-:SpectecTerminals TT-:SpectecTerminals) ; (field('FUNCS, eps) ; (field('DATAS, OK-:SpectecTerminals) ; (field('ELEMS, RT-3:SpectecTerminals) ; (field('LOCALS, eps) ; (field('LABELS, eps) ; (field('RETURN, eps) ; (field('REFS, eps) ; field('RECS, eps))))))))))))) }, context)
    /\ C-:SpectecTerminal == ({ (field('TYPES, DT--:SpectecTerminals) ; (field('TAGS, eps) ; (field('GLOBALS, GT-I-:SpectecTerminals) ; (field('MEMS, eps) ; (field('TABLES, eps) ; (field('FUNCS, DT-I-:SpectecTerminals DT-:SpectecTerminals) ; (field('DATAS, eps) ; (field('ELEMS, eps) ; (field('LOCALS, eps) ; (field('LABELS, eps) ; (field('RETURN, eps) ; (field('REFS, X-2:SpectecTerminals) ; field('RECS, eps))))))))))))) })
    /\ X-2:SpectecTerminals == funcidx-nonfuncs(tuple(seq(GLOBAL-:SpectecTerminals) (seq(MEM-:SpectecTerminals) (seq(TABLE-:SpectecTerminals) (seq(ELEM-:SpectecTerminals) (seq(START-:SpectecTerminals) seq(EXPORT-:SpectecTerminals)))))))
    /\ JT-I-:SpectecTerminals == tagsxt(XT-I-:SpectecTerminals)
    /\ GT-I-:SpectecTerminals == globalsxt(XT-I-:SpectecTerminals)
    /\ MT-I-:SpectecTerminals == memsxt(XT-I-:SpectecTerminals)
    /\ TT-I-:SpectecTerminals == tablesxt(XT-I-:SpectecTerminals)
    /\ DT-I-:SpectecTerminals == funcsxt(XT-I-:SpectecTerminals) .
```


<a id="externaddr-ok"></a>

## 5. `Externaddr_ok`

연결한 함수·메모리·테이블·전역 변수·태그의 실제 타입이 요구한 타입에 맞는지 판단한다.

**SpecTec 선언**


```spectec
relation Externaddr_ok: store |- externaddr : externtype  hint(macro "%externaddr") hint(maude_backend "check")
```

**Maude 선언**


```maude
op Externaddr-ok : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```

아래 `externaddr-ok`는 기본 외부 타입을 구한다. `Externaddr-ok` 공개 호출은 `externaddr-ok-sub` 검사로 연결한다.


### 5.1. `Externaddr_ok/tag`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:106)

**SpecTec**


```spectec
rule Externaddr_ok/tag:
  s |- TAG a : TAG taginst.TYPE
  -- if s.TAGS[a] = taginst
```

**의미**

store에서 주소 a의 태그 객체를 찾아 TYPE을 읽고, TAG 표시를 붙인 외부 타입을 얻는다. 이것은 외부 코드를 다운로드하거나 본문을 검증하는 동작이 아니다.

**Maude — 번역식 초안**


```maude
ceq externaddr-ok(S:SpectecTerminal, TAG(A:Nat)) = TAG(INST:SpectecTerminal . 'TYPE)
  if indexDefined(S:SpectecTerminal . 'TAGS, A:Nat)
    /\ INST:SpectecTerminal := (S:SpectecTerminal . 'TAGS)[A:Nat]
    /\ typecheck(INST:SpectecTerminal, taginst) .
```


### 5.2. `Externaddr_ok/global`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:110)

**SpecTec**


```spectec
rule Externaddr_ok/global:
  s |- GLOBAL a : GLOBAL globalinst.TYPE
  -- if s.GLOBALS[a] = globalinst
```

**의미**

store에서 주소 a의 전역 변수 객체를 찾아 TYPE을 읽고, GLOBAL 표시를 붙인 외부 타입을 얻는다. 이것은 외부 코드를 다운로드하거나 본문을 검증하는 동작이 아니다.

**Maude — 번역식 초안**


```maude
ceq externaddr-ok(S:SpectecTerminal, GLOBAL(A:Nat)) = GLOBAL(INST:SpectecTerminal . 'TYPE)
  if indexDefined(S:SpectecTerminal . 'GLOBALS, A:Nat)
    /\ INST:SpectecTerminal := (S:SpectecTerminal . 'GLOBALS)[A:Nat]
    /\ typecheck(INST:SpectecTerminal, globalinst) .
```


### 5.3. `Externaddr_ok/mem`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:114)

**SpecTec**


```spectec
rule Externaddr_ok/mem:
  s |- MEM a : MEM meminst.TYPE
  -- if s.MEMS[a] = meminst
```

**의미**

store에서 주소 a의 메모리 객체를 찾아 TYPE을 읽고, MEM 표시를 붙인 외부 타입을 얻는다. 이것은 외부 코드를 다운로드하거나 본문을 검증하는 동작이 아니다.

**Maude — 번역식 초안**


```maude
ceq externaddr-ok(S:SpectecTerminal, MEM(A:Nat)) = MEM(INST:SpectecTerminal . 'TYPE)
  if indexDefined(S:SpectecTerminal . 'MEMS, A:Nat)
    /\ INST:SpectecTerminal := (S:SpectecTerminal . 'MEMS)[A:Nat]
    /\ typecheck(INST:SpectecTerminal, meminst) .
```


### 5.4. `Externaddr_ok/table`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:118)

**SpecTec**


```spectec
rule Externaddr_ok/table:
  s |- TABLE a : TABLE tableinst.TYPE
  -- if s.TABLES[a] = tableinst
```

**의미**

store에서 주소 a의 테이블 객체를 찾아 TYPE을 읽고, TABLE 표시를 붙인 외부 타입을 얻는다. 이것은 외부 코드를 다운로드하거나 본문을 검증하는 동작이 아니다.

**Maude — 번역식 초안**


```maude
ceq externaddr-ok(S:SpectecTerminal, TABLE(A:Nat)) = TABLE(INST:SpectecTerminal . 'TYPE)
  if indexDefined(S:SpectecTerminal . 'TABLES, A:Nat)
    /\ INST:SpectecTerminal := (S:SpectecTerminal . 'TABLES)[A:Nat]
    /\ typecheck(INST:SpectecTerminal, tableinst) .
```


### 5.5. `Externaddr_ok/func`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:122)

**SpecTec**


```spectec
rule Externaddr_ok/func:
  s |- FUNC a : FUNC funcinst.TYPE
  -- if s.FUNCS[a] = funcinst
```

**의미**

store에서 주소 a의 함수 객체를 찾아 TYPE을 읽고, FUNC 표시를 붙인 외부 타입을 얻는다. 이것은 외부 코드를 다운로드하거나 본문을 검증하는 동작이 아니다.

**Maude — 번역식 초안**


```maude
ceq externaddr-ok(S:SpectecTerminal, FUNC(A:Nat)) = FUNC(INST:SpectecTerminal . 'TYPE)
  if indexDefined(S:SpectecTerminal . 'FUNCS, A:Nat)
    /\ INST:SpectecTerminal := (S:SpectecTerminal . 'FUNCS)[A:Nat]
    /\ typecheck(INST:SpectecTerminal, funcinst) .
```


### 5.6. `Externaddr_ok/sub`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:126)

**SpecTec**


```spectec
rule Externaddr_ok/sub:
  s |- externaddr : xt
  -- Externaddr_ok: s |- externaddr : xt'
  -- Externtype_ok: {} |- xt : OK
  -- Externtype_sub: {} |- xt' <: xt
```

**의미**

이미 인정한 외부 타입 xt'를 요청한 xt 자리에서 쓸 수 있는지 검사한다. xt의 유효성과 xt' <: xt를 함께 확인한다.

이 rule이 직접 호출하는 relation: `Externaddr_ok`, `Externtype_ok`, `Externtype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**

앞의 기본 rule로 직접 인정하는 경우와 subtype으로 추가 인정하는 경우를 함께 적었다. 기본 타입 계산으로 반복되는 subtype 인정을 묶는 구조이므로, 기본 타입의 유일성과 subtype 연결에 대한 별도 보존 논증이 필요하다. 이 문서의 load/smoke 검사는 그 증명이 아니다.


```maude
ceq externaddr-ok-sub(S:SpectecTerminal, A:SpectecTerminal, XT:SpectecTerminal) = true
  if XT:SpectecTerminal := externaddr-ok(S:SpectecTerminal, A:SpectecTerminal) .
ceq externaddr-ok-sub(S:SpectecTerminal, A:SpectecTerminal, XT:SpectecTerminal) = true
  if ACTUAL:SpectecTerminal := externaddr-ok(S:SpectecTerminal, A:SpectecTerminal)
    /\ Externtype-ok(empty-context, XT:SpectecTerminal)
    /\ Externtype-sub(empty-context, ACTUAL:SpectecTerminal, XT:SpectecTerminal) .
eq Externaddr-ok(S:SpectecTerminal, A:SpectecTerminal, XT:SpectecTerminal) = externaddr-ok-sub(S:SpectecTerminal, A:SpectecTerminal, XT:SpectecTerminal) .
```


<a id="reftype-ok"></a>

## 6. `Reftype_ok`

REF의 대상 타입이 이 문맥에서 올바른 타입인지 확인한다.

**SpecTec 선언**


```spectec
relation Reftype_ok: context |- reftype : OK    hint(name "K-ref")  hint(macro "%reftype")
```

**Maude 선언**


```maude
op Reftype-ok : SpectecTerminal SpectecTerminal ~> Bool .
```


### 6.1. `Reftype_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:30)

**SpecTec**


```spectec
rule Reftype_ok:
  C |- REF NULL? heaptype : OK
  -- Heaptype_ok: C |- heaptype : OK
```

**의미**

REF의 대상 타입이 이 문맥에서 올바른 타입인지 확인한다.

이 rule이 직접 호출하는 relation: `Heaptype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Reftype-ok(C:SpectecTerminal, REF(eps, HT:SpectecTerminal)) = true
  if Heaptype-ok(C:SpectecTerminal, HT:SpectecTerminal) .
ceq Reftype-ok(C:SpectecTerminal, REF(NULL ?, HT:SpectecTerminal)) = true
  if Heaptype-ok(C:SpectecTerminal, HT:SpectecTerminal) .
```


<a id="reftype-sub"></a>

## 7. `Reftype_sub`

첫 참조 타입의 값을 두 번째 참조 타입 자리에서 사용할 수 있는지 확인한다.

**SpecTec 선언**


```spectec
relation Reftype_sub: context |- reftype <: reftype    hint(name "S-ref")  hint(macro "%reftypematch")
```

**Maude 선언**


```maude
op Reftype-sub : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 7.1. `Reftype_sub/nonnull`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:105)

**SpecTec**


```spectec
rule Reftype_sub/nonnull:
  C |- REF ht_1 <: REF ht_2
  -- Heaptype_sub: C |- ht_1 <: ht_2
```

**의미**

null을 허용하지 않는 두 참조 타입 사이에서 대상 타입의 subtype을 확인한다.

이 rule이 직접 호출하는 relation: `Heaptype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Reftype-sub(C:SpectecTerminal, REF(eps, HT-1:SpectecTerminal), REF(eps, HT-2:SpectecTerminal)) = true
  if Heaptype-sub(C:SpectecTerminal, HT-1:SpectecTerminal, HT-2:SpectecTerminal) .
```


### 7.2. `Reftype_sub/null`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:109)

**SpecTec**


```spectec
rule Reftype_sub/null:
  C |- REF NULL? ht_1 <: REF NULL ht_2
  -- Heaptype_sub: C |- ht_1 <: ht_2
```

**의미**

요청 타입이 null을 허용하면 첫 타입의 null 허용 여부와 관계없이 대상 타입을 비교한다. 허용하지 않는 목표에 nullable 값을 넘기는 규칙은 아니다.

이 rule이 직접 호출하는 relation: `Heaptype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Reftype-sub(C:SpectecTerminal, REF(eps, H1:SpectecTerminal), REF(NULL ?, H2:SpectecTerminal)) = true
  if Heaptype-sub(C:SpectecTerminal, H1:SpectecTerminal, H2:SpectecTerminal) .
ceq Reftype-sub(C:SpectecTerminal, REF(NULL ?, H1:SpectecTerminal), REF(NULL ?, H2:SpectecTerminal)) = true
  if Heaptype-sub(C:SpectecTerminal, H1:SpectecTerminal, H2:SpectecTerminal) .
```


<a id="num-ok"></a>

## 8. `Num_ok`

CONST 숫자 값의 numtype 표시와 요청한 numtype이 같은지 확인한다.

**SpecTec 선언**


```spectec
relation Num_ok: store |- num : numtype  hint(macro "%num") hint(maude_predicate)
```

**Maude 선언**


```maude
op Num-ok : SpectecTerminal val SpectecTerminal ~> Bool .
```


### 8.1. `Num_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:28)

**SpecTec**


```spectec
rule Num_ok:
  s |- CONST nt c : nt
```

**의미**

CONST 숫자 값의 numtype 표시와 요청한 numtype이 같은지 확인한다.

**Maude — 번역식 초안**


```maude
eq Num-ok(S2:SpectecTerminal, CONST(NT:SpectecTerminal, C2:SpectecTerminal), NT:SpectecTerminal) = true .
```


<a id="vec-ok"></a>

## 9. `Vec_ok`

VCONST 벡터 값의 vectype 표시와 요청한 vectype이 같은지 확인한다.

**SpecTec 선언**


```spectec
relation Vec_ok: store |- vec : vectype  hint(macro "%vec") hint(maude_predicate)
```

**Maude 선언**


```maude
op Vec-ok : SpectecTerminal val SpectecTerminal ~> Bool .
```


### 9.1. `Vec_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:31)

**SpecTec**


```spectec
rule Vec_ok:
  s |- VCONST vt c : vt
```

**의미**

VCONST 벡터 값의 vectype 표시와 요청한 vectype이 같은지 확인한다.

**Maude — 번역식 초안**


```maude
eq Vec-ok(S2:SpectecTerminal, VCONST(VT:SpectecTerminal, C3:Nat), VT:SpectecTerminal) = true .
```


<a id="data-ok"></a>

## 10. `Data_ok`

data segment의 passive/active 모드와 offset 식을 검사한다.

**SpecTec 선언**


```spectec
relation Data_ok: context |- data : datatype         hint(name "T-data")     hint(macro "%data")  hint(prosepp "")
```

**Maude 선언**


```maude
op Data-ok : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 10.1. `Data_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:61)

**SpecTec**


```spectec
rule Data_ok:
  C |- DATA b* datamode : OK
  -- Datamode_ok: C |- datamode : OK
```

**의미**

data segment의 passive/active 모드와 offset 식을 검사한다.

이 rule이 직접 호출하는 relation: `Datamode_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Data-ok(C:SpectecTerminal, DATA(B-:SpectecTerminals, DATAMODE:SpectecTerminal), OK) = true
  if Datamode-ok(C:SpectecTerminal, DATAMODE:SpectecTerminal, OK) .
```


<a id="elem-ok"></a>

## 11. `Elem_ok`

element segment의 참조 타입, 초기화 식들, 배치 모드를 검사한다.

**SpecTec 선언**


```spectec
relation Elem_ok: context |- elem : elemtype         hint(name "T-elem")     hint(macro "%elem")
```

**Maude 선언**


```maude
op Elem-ok : SpectecTerminal SpectecTerminal ~> SpectecTerminal .
```


### 11.1. `Elem_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:65)

**SpecTec**


```spectec
rule Elem_ok:
  C |- ELEM elemtype expr* elemmode : elemtype
  -- Reftype_ok: C |- elemtype : OK
  -- (Expr_ok_const: C |- expr : elemtype CONST)*
  -- Elemmode_ok: C |- elemmode : elemtype
```

**의미**

element segment의 참조 타입, 초기화 식들, 배치 모드를 검사한다.

이 rule이 직접 호출하는 relation: `Elemmode_ok`, `Expr_ok_const`, `Reftype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Elem-ok(C:SpectecTerminal, ELEM(ELEMTYPE:SpectecTerminal, EXPR-:SpectecTerminals, ELEMMODE:SpectecTerminal)) = ELEMTYPE:SpectecTerminal
  if Reftype-ok(C:SpectecTerminal, ELEMTYPE:SpectecTerminal)
    /\ iterpr-24(C:SpectecTerminal, ELEMTYPE:SpectecTerminal, EXPR-:SpectecTerminals)
    /\ Elemmode-ok(C:SpectecTerminal, ELEMMODE:SpectecTerminal, ELEMTYPE:SpectecTerminal) .
```


<a id="export-ok"></a>

## 12. `Export_ok`

export의 이름과 가리키는 항목으로부터 외부 타입을 구한다.

**SpecTec 선언**


```spectec
relation Export_ok: context |- export : name externtype   hint(name "T-export")    hint(macro "%export")
```

**Maude 선언**


```maude
op Export-ok : SpectecTerminal SpectecTerminal ~> SpectecTerminal .
```


### 12.1. `Export_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:106)

**SpecTec**


```spectec
rule Export_ok:
  C |- EXPORT name externidx : name xt
  -- Externidx_ok: C |- externidx : xt
```

**의미**

export의 이름과 가리키는 항목으로부터 외부 타입을 구한다.

이 rule이 직접 호출하는 relation: `Externidx_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Export-ok(C:SpectecTerminal, EXPORT(NAME:SpectecTerminals, EXTERNIDX:SpectecTerminal)) = tuple(seq(NAME:SpectecTerminals) XT2:SpectecTerminal)
  if XT2:SpectecTerminal := Externidx-ok(C:SpectecTerminal, EXTERNIDX:SpectecTerminal) .
```


<a id="func-ok"></a>

## 13. `Func_ok`

함수의 선언 타입을 읽고 local 타입을 만들며 함수 본문의 결과 타입을 검사한다.

**SpecTec 선언**


```spectec
relation Func_ok: context |- func : deftype          hint(name "T-func")     hint(macro "%func")
```

**Maude 선언**


```maude
op Func-ok : SpectecTerminal SpectecTerminal ~> SpectecTerminal .
```


### 13.1. `Func_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:54)

**SpecTec**


```spectec
rule Func_ok:
  C |- FUNC x local* expr : C.TYPES[x]
  -- Expand: C.TYPES[x] ~~ FUNC t_1* -> t_2*
  -- (Local_ok: C |- local : lct)*
  ----
  -- Expr_ok: C ++ {LOCALS (SET t_1)* lct*, LABELS (t_2*), RETURN (t_2*)} |- expr : t_2*
```

**의미**

함수의 선언 타입을 읽고 local 타입을 만들며 함수 본문의 결과 타입을 검사한다.

이 rule이 직접 호출하는 relation: `Expand`, `Expr_ok`, `Local_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Func-ok(C:SpectecTerminal, spectec-FUNC-2(X:Nat, LS:SpectecTerminals, E:InstrList)) = DT:SpectecTerminal
  if DT:SpectecTerminal := (C:SpectecTerminal . 'TYPES)[X:Nat]
    /\ FUNC T1:SpectecTerminals -> T2:SpectecTerminals := Expand(DT:SpectecTerminal)
    /\ LCTS:SpectecTerminals := local-types(C:SpectecTerminal, LS:SpectecTerminals)
    /\ Expr-ok(recordConcat(C:SpectecTerminal, function-context(set-types(T1:SpectecTerminals) LCTS:SpectecTerminals, T2:SpectecTerminals), context), E:InstrList, T2:SpectecTerminals) .
```


<a id="globals-ok"></a>

## 14. `Globals_ok`

global 정의들을 순서대로 검사하여 다음 global의 문맥에 앞 global의 타입을 추가한다.

**SpecTec 선언**


```spectec
relation Globals_ok: context |- global* : globaltype* hint(name "T-globals") hint(macro "%globals")
```

**Maude 선언**


```maude
op Globals-ok : SpectecTerminal SpectecTerminals ~> SpectecTerminals .
```


### 14.1. `Globals_ok/empty`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:181)

**SpecTec**


```spectec
rule Globals_ok/empty:
  C |- eps : eps
```

**의미**

global 정의가 없으면 결과 global 타입 리스트도 비어 있다.

**Maude — 번역식 초안**


```maude
eq Globals-ok(C:SpectecTerminal, eps) = eps .
```


### 14.2. `Globals_ok/cons`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:184)

**SpecTec**


```spectec
rule Globals_ok/cons:
  C |- global_1 global* : gt_1 gt*
  -- Global_ok: C |- global_1 : gt_1
  -- Globals_ok: C ++ {GLOBALS gt_1} |- global* : gt*
```

**의미**

첫 global을 검사해 타입을 얻고 문맥 GLOBALS에 추가한 뒤 나머지를 검사한다.

이 rule이 직접 호출하는 relation: `Global_ok`, `Globals_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Globals-ok(C:SpectecTerminal, GLOBAL-1:SpectecTerminal GLOBAL-:SpectecTerminals) = GT-1:SpectecTerminal GT-:SpectecTerminals
  if GT-1:SpectecTerminal := Global-ok(C:SpectecTerminal, GLOBAL-1:SpectecTerminal)
    /\ GT-:SpectecTerminals := Globals-ok(recordConcat(C:SpectecTerminal, { (field('TYPES, eps) ; (field('TAGS, eps) ; (field('GLOBALS, GT-1:SpectecTerminal) ; (field('MEMS, eps) ; (field('TABLES, eps) ; (field('FUNCS, eps) ; (field('DATAS, eps) ; (field('ELEMS, eps) ; (field('LOCALS, eps) ; (field('LABELS, eps) ; (field('RETURN, eps) ; (field('REFS, eps) ; field('RECS, eps))))))))))))) }, context), GLOBAL-:SpectecTerminals) .
```


<a id="import-ok"></a>

## 15. `Import_ok`

import가 요구하는 외부 타입을 검사하고 현재 문맥으로 닫은 타입을 구한다.

**SpecTec 선언**


```spectec
relation Import_ok: context |- import : externtype        hint(name "T-import")    hint(macro "%import")
```

**Maude 선언**


```maude
op Import-ok : SpectecTerminal SpectecTerminal ~> SpectecTerminal .
```


### 15.1. `Import_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:102)

**SpecTec**


```spectec
rule Import_ok:
  C |- IMPORT name_1 name_2 xt : $clos_externtype(C, xt)
  -- Externtype_ok: C |- xt : OK
```

**의미**

import가 요구하는 외부 타입을 검사하고 현재 문맥으로 닫은 타입을 구한다.

이 rule이 직접 호출하는 relation: `Externtype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Import-ok(C:SpectecTerminal, IMPORT(NAME-1:SpectecTerminals, NAME-2:SpectecTerminals, XT2:SpectecTerminal)) = clos-externtype(C:SpectecTerminal, XT2:SpectecTerminal)
  if Externtype-ok(C:SpectecTerminal, XT2:SpectecTerminal) .
```


<a id="mem-ok"></a>

## 16. `Mem_ok`

memory 선언의 타입과 크기 제한이 올바른지 확인한다.

**SpecTec 선언**


```spectec
relation Mem_ok: context |- mem : memtype            hint(name "T-mem")      hint(macro "%mem")
```

**Maude 선언**


```maude
op Mem-ok : SpectecTerminal SpectecTerminal ~> SpectecTerminal .
```


### 16.1. `Mem_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:36)

**SpecTec**


```spectec
rule Mem_ok:
  C |- MEMORY memtype : memtype
  -- Memtype_ok: C |- memtype : OK
```

**의미**

memory 선언의 타입과 크기 제한이 올바른지 확인한다.

이 rule이 직접 호출하는 relation: `Memtype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Mem-ok(C:SpectecTerminal, MEMORY(MEMTYPE:SpectecTerminal)) = MEMTYPE:SpectecTerminal
  if Memtype-ok(C:SpectecTerminal, MEMTYPE:SpectecTerminal) .
```


<a id="start-ok"></a>

## 17. `Start_ok`

start 함수의 입력과 결과가 모두 빈 리스트인지 확인한다.

**SpecTec 선언**


```spectec
relation Start_ok: context |- start : OK             hint(name "T-start")    hint(macro "%start")
```

**Maude 선언**


```maude
op Start-ok : SpectecTerminal SpectecTerminal ~> Bool .
```


### 17.1. `Start_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:91)

**SpecTec**


```spectec
rule Start_ok:
  C |- START x : OK
  -- Expand: C.FUNCS[x] ~~ FUNC eps -> eps
```

**의미**

start 함수의 입력과 결과가 모두 빈 리스트인지 확인한다.

이 rule이 직접 호출하는 relation: `Expand`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Start-ok(C:SpectecTerminal, START(X4:Nat)) = true
  if FUNC eps -> eps = Expand((C:SpectecTerminal . 'FUNCS) [ X4:Nat ]) .
```


<a id="table-ok"></a>

## 18. `Table_ok`

table의 타입과 초기화 식의 참조 타입을 확인한다.

**SpecTec 선언**


```spectec
relation Table_ok: context |- table : tabletype      hint(name "T-table")    hint(macro "%table")
```

**Maude 선언**


```maude
op Table-ok : SpectecTerminal SpectecTerminal ~> SpectecTerminal .
```


### 18.1. `Table_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:40)

**SpecTec**


```spectec
rule Table_ok:
  C |- TABLE tabletype expr : tabletype
  -- Tabletype_ok: C |- tabletype : OK
  -- if tabletype = at lim rt
  -- Expr_ok_const: C |- expr : rt CONST
```

**의미**

table의 타입과 초기화 식의 참조 타입을 확인한다.

이 rule이 직접 호출하는 relation: `Expr_ok_const`, `Tabletype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Table-ok(C:SpectecTerminal, spectec-TABLE(TABLETYPE:SpectecTerminal, EXPR:InstrList)) = TABLETYPE:SpectecTerminal
  if Tabletype-ok(C:SpectecTerminal, TABLETYPE:SpectecTerminal)
    /\ tuple(AT:SpectecTerminal (LIM:SpectecTerminal RT:SpectecTerminal)) := TABLETYPE:SpectecTerminal
    /\ Expr-ok-const(C:SpectecTerminal, EXPR:InstrList, RT:SpectecTerminal) .
```


<a id="tag-ok"></a>

## 19. `Tag_ok`

tag의 함수 타입 사용을 검사하고 닫은 tag 타입을 구한다.

**SpecTec 선언**


```spectec
relation Tag_ok: context |- tag : tagtype            hint(name "T-tag")      hint(macro "%tag")
```

**Maude 선언**


```maude
op Tag-ok : SpectecTerminal SpectecTerminal ~> SpectecTerminal .
```


### 19.1. `Tag_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:26)

**SpecTec**


```spectec
rule Tag_ok:
  C |- TAG tagtype : $clos_tagtype(C, tagtype)
  -- Tagtype_ok: C |- tagtype : OK
```

**의미**

tag의 함수 타입 사용을 검사하고 닫은 tag 타입을 구한다.

이 rule이 직접 호출하는 relation: `Tagtype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Tag-ok(C:SpectecTerminal, TAG(TAGTYPE:SpectecTerminal)) = clos-tagtype(C:SpectecTerminal, TAGTYPE:SpectecTerminal)
  if Tagtype-ok(C:SpectecTerminal, TAGTYPE:SpectecTerminal) .
```


<a id="types-ok"></a>

## 20. `Types_ok`

type 정의 리스트를 앞에서부터 검사하고, 얻은 정의 타입을 다음 정의의 문맥에 추가한다.

**SpecTec 선언**


```spectec
relation Types_ok: context |- type* : deftype*        hint(name "T-types")   hint(macro "%types")
```

**Maude 선언**


```maude
op Types-ok : SpectecTerminal SpectecTerminals ~> SpectecTerminals .
```


### 20.1. `Types_ok/empty`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:173)

**SpecTec**


```spectec
rule Types_ok/empty:
  C |- eps : eps
```

**의미**

type 정의가 없으면 새 정의 타입 리스트도 비어 있다.

**Maude — 번역식 초안**


```maude
eq Types-ok(C:SpectecTerminal, eps) = eps .
```


### 20.2. `Types_ok/cons`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:176)

**SpecTec**


```spectec
rule Types_ok/cons:
  C |- type_1 type* : dt_1* dt*
  -- Type_ok: C |- type_1 : dt_1*
  -- Types_ok: C ++ {TYPES dt_1*} |- type* : dt*
```

**의미**

첫 type에서 얻은 정의 타입들을 문맥 TYPES 뒤에 붙이고 나머지 type들을 검사한다.

이 rule이 직접 호출하는 relation: `Type_ok`, `Types_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Types-ok(C:SpectecTerminal, TYPE-1:SpectecTerminal TYPE-:SpectecTerminals) = DT-1-:SpectecTerminals DT-:SpectecTerminals
  if DT-1-:SpectecTerminals := Type-ok(C:SpectecTerminal, TYPE-1:SpectecTerminal)
    /\ DT-:SpectecTerminals := Types-ok(recordConcat(C:SpectecTerminal, { (field('TYPES, DT-1-:SpectecTerminals) ; (field('TAGS, eps) ; (field('GLOBALS, eps) ; (field('MEMS, eps) ; (field('TABLES, eps) ; (field('FUNCS, eps) ; (field('DATAS, eps) ; (field('ELEMS, eps) ; (field('LOCALS, eps) ; (field('LABELS, eps) ; (field('RETURN, eps) ; (field('REFS, eps) ; field('RECS, eps))))))))))))) }, context), TYPE-:SpectecTerminals) .
```


<a id="externtype-ok"></a>

## 21. `Externtype_ok`

외부에서 가져오거나 내보내는 타입 자체가 올바른지 확인한다.

**SpecTec 선언**


```spectec
relation Externtype_ok: context |- externtype : OK  hint(name "K-extern") hint(macro "%externtype")
```

**Maude 선언**


```maude
op Externtype-ok : SpectecTerminal SpectecTerminal ~> Bool .
```


### 21.1. `Externtype_ok/tag`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:238)

**SpecTec**


```spectec
rule Externtype_ok/tag:
  C |- TAG tagtype : OK
  -- Tagtype_ok: C |- tagtype : OK
```

**의미**

외부에서 가져오거나 내보내는 타입 자체가 올바른지 확인한다. 이 rule은 `tag` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

이 rule이 직접 호출하는 relation: `Tagtype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Externtype-ok(C:SpectecTerminal, TAG(TAGTYPE:SpectecTerminal)) = true
  if Tagtype-ok(C:SpectecTerminal, TAGTYPE:SpectecTerminal) .
```


### 21.2. `Externtype_ok/global`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:242)

**SpecTec**


```spectec
rule Externtype_ok/global:
  C |- GLOBAL globaltype : OK
  -- Globaltype_ok: C |- globaltype : OK
```

**의미**

외부에서 가져오거나 내보내는 타입 자체가 올바른지 확인한다. 이 rule은 `global` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

이 rule이 직접 호출하는 relation: `Globaltype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Externtype-ok(C:SpectecTerminal, GLOBAL(GLOBALTYPE:SpectecTerminal)) = true
  if Globaltype-ok(C:SpectecTerminal, GLOBALTYPE:SpectecTerminal) .
```


### 21.3. `Externtype_ok/mem`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:246)

**SpecTec**


```spectec
rule Externtype_ok/mem:
  C |- MEM memtype : OK
  -- Memtype_ok: C |- memtype : OK
```

**의미**

외부에서 가져오거나 내보내는 타입 자체가 올바른지 확인한다. 이 rule은 `mem` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

이 rule이 직접 호출하는 relation: `Memtype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Externtype-ok(C:SpectecTerminal, MEM(MEMTYPE:SpectecTerminal)) = true
  if Memtype-ok(C:SpectecTerminal, MEMTYPE:SpectecTerminal) .
```


### 21.4. `Externtype_ok/table`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:250)

**SpecTec**


```spectec
rule Externtype_ok/table:
  C |- TABLE tabletype : OK
  -- Tabletype_ok: C |- tabletype : OK
```

**의미**

외부에서 가져오거나 내보내는 타입 자체가 올바른지 확인한다. 이 rule은 `table` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

이 rule이 직접 호출하는 relation: `Tabletype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Externtype-ok(C:SpectecTerminal, TABLE(TABLETYPE:SpectecTerminal)) = true
  if Tabletype-ok(C:SpectecTerminal, TABLETYPE:SpectecTerminal) .
```


### 21.5. `Externtype_ok/func`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:254)

**SpecTec**


```spectec
rule Externtype_ok/func:
  C |- FUNC typeuse : OK
  -- Typeuse_ok: C |- typeuse : OK
  -- Expand_use: typeuse ~~_C $($(FUNC t_1* -> t_2*))
```

**의미**

외부에서 가져오거나 내보내는 타입 자체가 올바른지 확인한다. 이 rule은 `func` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

이 rule이 직접 호출하는 relation: `Expand_use`, `Typeuse_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Externtype-ok(C:SpectecTerminal, FUNC(TYPEUSE:SpectecTerminal)) = true
  if Typeuse-ok(C:SpectecTerminal, TYPEUSE:SpectecTerminal)
    /\ FUNC T-1-:SpectecTerminals -> T-2-:SpectecTerminals := Expand-use(TYPEUSE:SpectecTerminal, C:SpectecTerminal) .
```


<a id="externtype-sub"></a>

## 22. `Externtype_sub`

실제로 제공하는 외부 항목을 요구한 외부 타입으로 연결해도 되는지 확인한다.

**SpecTec 선언**


```spectec
relation Externtype_sub: context |- externtype <: externtype hint(name "S-extern") hint(macro "%externtypematch")
```

**Maude 선언**


```maude
op Externtype-sub : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 22.1. `Externtype_sub/tag`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:250)

**SpecTec**


```spectec
rule Externtype_sub/tag:
  C |- TAG tagtype_1 <: TAG tagtype_2
  -- Tagtype_sub: C |- tagtype_1 <: tagtype_2
```

**의미**

실제로 제공하는 외부 항목을 요구한 외부 타입으로 연결해도 되는지 확인한다. 이 rule은 `tag` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

이 rule이 직접 호출하는 relation: `Tagtype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Externtype-sub(C:SpectecTerminal, TAG(TAGTYPE-1:SpectecTerminal), TAG(TAGTYPE-2:SpectecTerminal)) = true
  if Tagtype-sub(C:SpectecTerminal, TAGTYPE-1:SpectecTerminal, TAGTYPE-2:SpectecTerminal) .
```


### 22.2. `Externtype_sub/global`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:254)

**SpecTec**


```spectec
rule Externtype_sub/global:
  C |- GLOBAL globaltype_1 <: GLOBAL globaltype_2
  -- Globaltype_sub: C |- globaltype_1 <: globaltype_2
```

**의미**

실제로 제공하는 외부 항목을 요구한 외부 타입으로 연결해도 되는지 확인한다. 이 rule은 `global` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

이 rule이 직접 호출하는 relation: `Globaltype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Externtype-sub(C:SpectecTerminal, GLOBAL(GLOBALTYPE-1:SpectecTerminal), GLOBAL(GLOBALTYPE-2:SpectecTerminal)) = true
  if Globaltype-sub(C:SpectecTerminal, GLOBALTYPE-1:SpectecTerminal, GLOBALTYPE-2:SpectecTerminal) .
```


### 22.3. `Externtype_sub/mem`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:258)

**SpecTec**


```spectec
rule Externtype_sub/mem:
  C |- MEM memtype_1 <: MEM memtype_2
  -- Memtype_sub: C |- memtype_1 <: memtype_2
```

**의미**

실제로 제공하는 외부 항목을 요구한 외부 타입으로 연결해도 되는지 확인한다. 이 rule은 `mem` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

이 rule이 직접 호출하는 relation: `Memtype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Externtype-sub(C:SpectecTerminal, MEM(MEMTYPE-1:SpectecTerminal), MEM(MEMTYPE-2:SpectecTerminal)) = true
  if Memtype-sub(C:SpectecTerminal, MEMTYPE-1:SpectecTerminal, MEMTYPE-2:SpectecTerminal) .
```


### 22.4. `Externtype_sub/table`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:262)

**SpecTec**


```spectec
rule Externtype_sub/table:
  C |- TABLE tabletype_1 <: TABLE tabletype_2
  -- Tabletype_sub: C |- tabletype_1 <: tabletype_2
```

**의미**

실제로 제공하는 외부 항목을 요구한 외부 타입으로 연결해도 되는지 확인한다. 이 rule은 `table` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

이 rule이 직접 호출하는 relation: `Tabletype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Externtype-sub(C:SpectecTerminal, TABLE(TABLETYPE-1:SpectecTerminal), TABLE(TABLETYPE-2:SpectecTerminal)) = true
  if Tabletype-sub(C:SpectecTerminal, TABLETYPE-1:SpectecTerminal, TABLETYPE-2:SpectecTerminal) .
```


### 22.5. `Externtype_sub/func`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:266)

**SpecTec**


```spectec
rule Externtype_sub/func:
  C |- FUNC deftype_1 <: FUNC deftype_2
  -- Deftype_sub: C |- deftype_1 <: deftype_2
```

**의미**

실제로 제공하는 외부 항목을 요구한 외부 타입으로 연결해도 되는지 확인한다. 이 rule은 `func` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

이 rule이 직접 호출하는 relation: `Deftype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Externtype-sub(C:SpectecTerminal, FUNC(DEFTYPE-1:SpectecTerminal), FUNC(DEFTYPE-2:SpectecTerminal)) = true
  if typecheck(DEFTYPE-1:SpectecTerminal, deftype)
    /\ typecheck(DEFTYPE-2:SpectecTerminal, deftype)
    /\ Deftype-sub(C:SpectecTerminal, DEFTYPE-1:SpectecTerminal, DEFTYPE-2:SpectecTerminal) .
```


<a id="heaptype-ok"></a>

## 23. `Heaptype_ok`

참조 대상 종류나 정의 타입·타입 번호가 문맥에서 올바른지 확인한다.

**SpecTec 선언**


```spectec
relation Heaptype_ok: context |- heaptype : OK  hint(name "K-heap") hint(macro "%heaptype")
```

**Maude 선언**


```maude
op Heaptype-ok : SpectecTerminal SpectecTerminal ~> Bool .
```


### 23.1. `Heaptype_ok/abs`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:20)

**SpecTec**


```spectec
rule Heaptype_ok/abs:
  C |- absheaptype : OK
```

**의미**

참조 대상 종류나 정의 타입·타입 번호가 문맥에서 올바른지 확인한다.

**Maude — 번역식 초안**


```maude
ceq Heaptype-ok(C:SpectecTerminal, ABSHEAPTYPE:SpectecTerminal) = true
  if typecheck(ABSHEAPTYPE:SpectecTerminal, absheaptype) .
```


### 23.2. `Heaptype_ok/typeuse`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:23)

**SpecTec**


```spectec
rule Heaptype_ok/typeuse:
  C |- typeuse : OK
  -- Typeuse_ok: C |- typeuse : OK
```

**의미**

참조 대상 종류나 정의 타입·타입 번호가 문맥에서 올바른지 확인한다.

이 rule이 직접 호출하는 relation: `Typeuse_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Heaptype-ok(C:SpectecTerminal, TYPEUSE:SpectecTerminal) = true
  if typecheck(TYPEUSE:SpectecTerminal, typeuse)
    /\ Typeuse-ok(C:SpectecTerminal, TYPEUSE:SpectecTerminal) .
```


### 23.3. `Heaptype_ok/bot`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:27)

**SpecTec**


```spectec
rule Heaptype_ok/bot:
  C |- BOT : OK
```

**의미**

참조 대상 종류나 정의 타입·타입 번호가 문맥에서 올바른지 확인한다.

**Maude — 번역식 초안**


```maude
eq Heaptype-ok(C:SpectecTerminal, BOT) = true .
```


<a id="heaptype-sub"></a>

## 24. `Heaptype_sub`

참조 대상 타입 사이의 subtype 관계를 판단한다.

**SpecTec 선언**


```spectec
relation Heaptype_sub: context |- heaptype <: heaptype hint(name "S-heap") hint(macro "%heaptypematch")
```

**Maude 선언**


```maude
op Heaptype-sub : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 24.1. `Heaptype_sub/refl`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:20)

**SpecTec**


```spectec
rule Heaptype_sub/refl:
  C |- heaptype <: heaptype
```

**의미**

어떤 대상 타입이든 자기 자신과 같은 타입으로 사용할 수 있다.

**Maude — 번역식 초안**


```maude
eq Heaptype-sub(C:SpectecTerminal, HEAPTYPE:SpectecTerminal, HEAPTYPE:SpectecTerminal) = true .
```


### 24.2. `Heaptype_sub/trans`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:23)

**SpecTec**


```spectec
rule Heaptype_sub/trans:
  C |- heaptype_1 <: heaptype_2
  -- Heaptype_ok: C |- heaptype' : OK
  -- Heaptype_sub: C |- heaptype_1 <: heaptype'
  -- Heaptype_sub: C |- heaptype' <: heaptype_2
```

**의미**

중간 타입 하나를 통해 두 subtype 판단을 연결한다. I31 <: EQ와 EQ <: ANY를 합쳐 I31 <: ANY를 인정한다. 중간 heaptype'는 입력에 없으므로 찾아야 한다.

이 rule이 직접 호출하는 relation: `Heaptype_ok`, `Heaptype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 추가 입력을 받은 조건 검사식. 원래 호출에 대한 완성된 판정기는 아님.**


```maude
op Heaptype-sub-via-trans : SpectecTerminal SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
ceq Heaptype-sub-via-trans(C:SpectecTerminal, H1:SpectecTerminal, H2:SpectecTerminal, MID:SpectecTerminal) = true
  if Heaptype-ok(C:SpectecTerminal, MID:SpectecTerminal)
    /\ Heaptype-sub(C:SpectecTerminal, H1:SpectecTerminal, MID:SpectecTerminal)
    /\ Heaptype-sub(C:SpectecTerminal, MID:SpectecTerminal, H2:SpectecTerminal) .
```


### 24.3. `Heaptype_sub/eq-any`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:29)

**SpecTec**


```spectec
rule Heaptype_sub/eq-any:
  C |- EQ <: ANY
```

**의미**

EQ 종류의 대상은 ANY 자리에서 사용할 수 있다.

**Maude — 번역식 초안**


```maude
eq Heaptype-sub(C:SpectecTerminal, EQ, ANY) = true .
```


### 24.4. `Heaptype_sub/i31-eq`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:32)

**SpecTec**


```spectec
rule Heaptype_sub/i31-eq:
  C |- I31 <: EQ
```

**의미**

i31 대상은 EQ 자리에서 사용할 수 있다.

**Maude — 번역식 초안**


```maude
eq Heaptype-sub(C:SpectecTerminal, I31, EQ) = true .
```


### 24.5. `Heaptype_sub/struct-eq`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:35)

**SpecTec**


```spectec
rule Heaptype_sub/struct-eq:
  C |- STRUCT <: EQ
```

**의미**

struct 대상은 EQ 자리에서 사용할 수 있다.

**Maude — 번역식 초안**


```maude
eq Heaptype-sub(C:SpectecTerminal, STRUCT, EQ) = true .
```


### 24.6. `Heaptype_sub/array-eq`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:38)

**SpecTec**


```spectec
rule Heaptype_sub/array-eq:
  C |- ARRAY <: EQ
```

**의미**

array 대상은 EQ 자리에서 사용할 수 있다.

**Maude — 번역식 초안**


```maude
eq Heaptype-sub(C:SpectecTerminal, ARRAY, EQ) = true .
```


### 24.7. `Heaptype_sub/struct`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:41)

**SpecTec**


```spectec
rule Heaptype_sub/struct:
  C |- deftype <: STRUCT
  -- Expand: deftype ~~ STRUCT fieldtype*
```

**의미**

정의 타입이 STRUCT 구성 타입으로 펼쳐지면 그 추상 대상 종류의 subtype으로 인정한다.

이 rule이 직접 호출하는 relation: `Expand`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Heaptype-sub(C:SpectecTerminal, DEFTYPE:SpectecTerminal, STRUCT) = true
  if typecheck(DEFTYPE:SpectecTerminal, deftype)
    /\ spectec-STRUCT(FIELDTYPE-:SpectecTerminals) := Expand(DEFTYPE:SpectecTerminal) .
```


### 24.8. `Heaptype_sub/array`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:45)

**SpecTec**


```spectec
rule Heaptype_sub/array:
  C |- deftype <: ARRAY
  -- Expand: deftype ~~ ARRAY fieldtype
```

**의미**

정의 타입이 ARRAY 구성 타입으로 펼쳐지면 그 추상 대상 종류의 subtype으로 인정한다.

이 rule이 직접 호출하는 relation: `Expand`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Heaptype-sub(C:SpectecTerminal, DEFTYPE:SpectecTerminal, ARRAY) = true
  if typecheck(DEFTYPE:SpectecTerminal, deftype)
    /\ spectec-ARRAY(FIELDTYPE:SpectecTerminal) := Expand(DEFTYPE:SpectecTerminal) .
```


### 24.9. `Heaptype_sub/func`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:49)

**SpecTec**


```spectec
rule Heaptype_sub/func:
  C |- deftype <: FUNC
  -- Expand: deftype ~~ FUNC t_1* -> t_2*
```

**의미**

정의 타입이 FUNC 구성 타입으로 펼쳐지면 그 추상 대상 종류의 subtype으로 인정한다.

이 rule이 직접 호출하는 relation: `Expand`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Heaptype-sub(C:SpectecTerminal, DEFTYPE:SpectecTerminal, spectec-FUNC) = true
  if typecheck(DEFTYPE:SpectecTerminal, deftype)
    /\ FUNC T-1-:SpectecTerminals -> T-2-:SpectecTerminals := Expand(DEFTYPE:SpectecTerminal) .
```


### 24.10. `Heaptype_sub/def`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:53)

**SpecTec**


```spectec
rule Heaptype_sub/def:
  C |- deftype_1 <: deftype_2
  -- Deftype_sub: C |- deftype_1 <: deftype_2
```

**의미**

참조 대상 타입 사이의 subtype 관계를 판단한다.

이 rule이 직접 호출하는 relation: `Deftype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Heaptype-sub(C:SpectecTerminal, DEFTYPE-1:SpectecTerminal, DEFTYPE-2:SpectecTerminal) = true
  if typecheck(DEFTYPE-1:SpectecTerminal, deftype)
    /\ typecheck(DEFTYPE-2:SpectecTerminal, deftype)
    /\ Deftype-sub(C:SpectecTerminal, DEFTYPE-1:SpectecTerminal, DEFTYPE-2:SpectecTerminal) .
```


### 24.11. `Heaptype_sub/typeidx-l`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:57)

**SpecTec**


```spectec
rule Heaptype_sub/typeidx-l:
  C |- _IDX typeidx <: heaptype
  -- Heaptype_sub: C |- C.TYPES[typeidx] <: heaptype
```

**의미**

타입 번호를 문맥 TYPES의 실제 정의 타입으로 바꾸어 같은 subtype 판단을 수행한다.

이 rule이 직접 호출하는 relation: `Heaptype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Heaptype-sub(C:SpectecTerminal, -IDX(TYPEIDX:Nat), HEAPTYPE:SpectecTerminal) = true
  if Heaptype-sub(C:SpectecTerminal, (C:SpectecTerminal . 'TYPES) [ TYPEIDX:Nat ], HEAPTYPE:SpectecTerminal) .
```


### 24.12. `Heaptype_sub/typeidx-r`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:61)

**SpecTec**


```spectec
rule Heaptype_sub/typeidx-r:
  C |- heaptype <: _IDX typeidx
  -- Heaptype_sub: C |- heaptype <: C.TYPES[typeidx]
```

**의미**

타입 번호를 문맥 TYPES의 실제 정의 타입으로 바꾸어 같은 subtype 판단을 수행한다.

이 rule이 직접 호출하는 relation: `Heaptype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Heaptype-sub(C:SpectecTerminal, HEAPTYPE:SpectecTerminal, -IDX(TYPEIDX:Nat)) = true
  if Heaptype-sub(C:SpectecTerminal, HEAPTYPE:SpectecTerminal, (C:SpectecTerminal . 'TYPES) [ TYPEIDX:Nat ]) .
```


### 24.13. `Heaptype_sub/rec-struct`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:65)

**SpecTec**


```spectec
rule Heaptype_sub/rec-struct:
  C |- REC i <: STRUCT
  -- if C.RECS[i] = SUB final? (STRUCT fieldtype*)
```

**의미**

문맥 RECS에서 재귀 타입 항목을 읽어 아래 결론의 추상 대상 종류로 인정한다.

**Maude — 번역식 초안**


```maude
ceq Heaptype-sub(C:SpectecTerminal, REC(I:Nat), STRUCT) = true
  if SUB(FINAL-:SpectecTerminals, eps, spectec-STRUCT(FIELDTYPE-:SpectecTerminals)) := (C:SpectecTerminal . 'RECS) [ I:Nat ]
    /\ len(FINAL-:SpectecTerminals) <= 1 .
```


### 24.14. `Heaptype_sub/rec-array`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:69)

**SpecTec**


```spectec
rule Heaptype_sub/rec-array:
  C |- REC i <: ARRAY
  -- if C.RECS[i] = SUB final? (ARRAY fieldtype)
```

**의미**

문맥 RECS에서 재귀 타입 항목을 읽어 아래 결론의 추상 대상 종류로 인정한다.

**Maude — 번역식 초안**


```maude
ceq Heaptype-sub(C:SpectecTerminal, REC(I:Nat), ARRAY) = true
  if SUB(FINAL-:SpectecTerminals, eps, spectec-ARRAY(FIELDTYPE:SpectecTerminal)) := (C:SpectecTerminal . 'RECS) [ I:Nat ]
    /\ len(FINAL-:SpectecTerminals) <= 1 .
```


### 24.15. `Heaptype_sub/rec-func`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:73)

**SpecTec**


```spectec
rule Heaptype_sub/rec-func:
  C |- REC i <: FUNC
  -- if C.RECS[i] = SUB final? (FUNC t_1* -> t_2*)
```

**의미**

문맥 RECS에서 재귀 타입 항목을 읽어 아래 결론의 추상 대상 종류로 인정한다.

**Maude — 번역식 초안**


```maude
ceq Heaptype-sub(C:SpectecTerminal, REC(I:Nat), spectec-FUNC) = true
  if SUB(FINAL-:SpectecTerminals, eps, FUNC T-1-:SpectecTerminals -> T-2-:SpectecTerminals) := (C:SpectecTerminal . 'RECS) [ I:Nat ]
    /\ len(FINAL-:SpectecTerminals) <= 1 .
```


### 24.16. `Heaptype_sub/rec-sub`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:77)

**SpecTec**


```spectec
rule Heaptype_sub/rec-sub:
  C |- REC i <: typeuse*[j]
  -- if C.RECS[i] = SUB final? typeuse* ct
```

**의미**

재귀 그룹의 i번째 타입에 적힌 상위 타입 리스트에서 j번째 타입을 골라 그 상위 타입으로 인정한다. Maude에서는 prefix/원소/suffix 매칭으로 같은 원소 선택을 표현한다.

**Maude — 번역식 초안**

source의 리스트 인덱스 witness는 prefix/선택 원소/suffix의 associative matching으로 표현한다. 원문에서 선택 가능한 원소 전체를 유지한다.


```maude
ceq Heaptype-sub(C:SpectecTerminal, REC(I:Nat), HT:SpectecTerminal) = true
  if SUB(FIN:SpectecTerminals, TUS:SpectecTerminals, CT:SpectecTerminal) := (C:SpectecTerminal . 'RECS)[I:Nat]
    /\ PREFIX:SpectecTerminals HT:SpectecTerminal SUFFIX:SpectecTerminals := TUS:SpectecTerminals .
```


### 24.17. `Heaptype_sub/none`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:81)

**SpecTec**


```spectec
rule Heaptype_sub/none:
  C |- NONE <: heaptype
  -- Heaptype_sub: C |- heaptype <: ANY
  -- if heaptype =/= BOT
```

**의미**

해당 참조 종류의 가장 아래 타입을 같은 종류의 상위 타입에 사용할 수 있다. 원문의 heaptype =/= BOT 조건은 유지한다.

이 rule이 직접 호출하는 relation: `Heaptype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Heaptype-sub(C:SpectecTerminal, NONE, HEAPTYPE:SpectecTerminal) = true
  if Heaptype-sub(C:SpectecTerminal, HEAPTYPE:SpectecTerminal, ANY)
    /\ HEAPTYPE:SpectecTerminal =/= BOT .
```


### 24.18. `Heaptype_sub/nofunc`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:86)

**SpecTec**


```spectec
rule Heaptype_sub/nofunc:
  C |- NOFUNC <: heaptype
  -- Heaptype_sub: C |- heaptype <: FUNC
  -- if heaptype =/= BOT
```

**의미**

해당 참조 종류의 가장 아래 타입을 같은 종류의 상위 타입에 사용할 수 있다. 원문의 heaptype =/= BOT 조건은 유지한다.

이 rule이 직접 호출하는 relation: `Heaptype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Heaptype-sub(C:SpectecTerminal, NOFUNC, HEAPTYPE:SpectecTerminal) = true
  if Heaptype-sub(C:SpectecTerminal, HEAPTYPE:SpectecTerminal, spectec-FUNC)
    /\ HEAPTYPE:SpectecTerminal =/= BOT .
```


### 24.19. `Heaptype_sub/noexn`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:91)

**SpecTec**


```spectec
rule Heaptype_sub/noexn:
  C |- NOEXN <: heaptype
  -- Heaptype_sub: C |- heaptype <: EXN
  -- if heaptype =/= BOT
```

**의미**

해당 참조 종류의 가장 아래 타입을 같은 종류의 상위 타입에 사용할 수 있다. 원문의 heaptype =/= BOT 조건은 유지한다.

이 rule이 직접 호출하는 relation: `Heaptype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Heaptype-sub(C:SpectecTerminal, NOEXN, HEAPTYPE:SpectecTerminal) = true
  if Heaptype-sub(C:SpectecTerminal, HEAPTYPE:SpectecTerminal, EXN)
    /\ HEAPTYPE:SpectecTerminal =/= BOT .
```


### 24.20. `Heaptype_sub/noextern`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:96)

**SpecTec**


```spectec
rule Heaptype_sub/noextern:
  C |- NOEXTERN <: heaptype
  -- Heaptype_sub: C |- heaptype <: EXTERN
  -- if heaptype =/= BOT
```

**의미**

해당 참조 종류의 가장 아래 타입을 같은 종류의 상위 타입에 사용할 수 있다. 원문의 heaptype =/= BOT 조건은 유지한다.

이 rule이 직접 호출하는 relation: `Heaptype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Heaptype-sub(C:SpectecTerminal, NOEXTERN, HEAPTYPE:SpectecTerminal) = true
  if Heaptype-sub(C:SpectecTerminal, HEAPTYPE:SpectecTerminal, EXTERN)
    /\ HEAPTYPE:SpectecTerminal =/= BOT .
```


### 24.21. `Heaptype_sub/bot`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:101)

**SpecTec**


```spectec
rule Heaptype_sub/bot:
  C |- BOT <: heaptype
```

**의미**

BOT는 모든 heaptype의 subtype으로 인정한다.

**Maude — 번역식 초안**


```maude
eq Heaptype-sub(C:SpectecTerminal, BOT, HEAPTYPE:SpectecTerminal) = true .
```


<a id="datamode-ok"></a>

## 25. `Datamode_ok`

active data의 대상 memory와 offset의 주소 타입을 검사한다. passive에는 offset 검사가 없다.

**SpecTec 선언**


```spectec
relation Datamode_ok: context |- datamode : datatype hint(name "T-datamode") hint(macro "%datamode") hint(prosepp "")
```

**Maude 선언**


```maude
op Datamode-ok : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 25.1. `Datamode_ok/passive`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:71)

**SpecTec**


```spectec
rule Datamode_ok/passive:
  C |- PASSIVE : OK
```

**의미**

active data의 대상 memory와 offset의 주소 타입을 검사한다. passive에는 offset 검사가 없다.

**Maude — 번역식 초안**


```maude
eq Datamode-ok(C:SpectecTerminal, PASSIVE, OK) = true .
```


### 25.2. `Datamode_ok/active`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:74)

**SpecTec**


```spectec
rule Datamode_ok/active:
  C |- ACTIVE x expr : OK
  -- if C.MEMS[x] = at lim PAGE
  -- Expr_ok_const: C |- expr : at CONST
```

**의미**

active data의 대상 memory와 offset의 주소 타입을 검사한다. passive에는 offset 검사가 없다.

이 rule이 직접 호출하는 relation: `Expr_ok_const`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Datamode-ok(C:SpectecTerminal, ACTIVE(X4:Nat, EXPR:InstrList), OK) = true
  if __PAGE(AT:SpectecTerminal, LIM:SpectecTerminal) := (C:SpectecTerminal . 'MEMS) [ X4:Nat ]
    /\ Expr-ok-const(C:SpectecTerminal, EXPR:InstrList, AT:SpectecTerminal) .
```


<a id="elemmode-ok"></a>

## 26. `Elemmode_ok`

active element의 대상 table, 원소 subtype, offset을 검사한다. passive/declare에는 이 배치 검사가 없다.

**SpecTec 선언**


```spectec
relation Elemmode_ok: context |- elemmode : elemtype hint(name "T-elemmode") hint(macro "%elemmode")
```

**Maude 선언**


```maude
op Elemmode-ok : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 26.1. `Elemmode_ok/passive`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:79)

**SpecTec**


```spectec
rule Elemmode_ok/passive:
  C |- PASSIVE : rt
```

**의미**

active element의 대상 table, 원소 subtype, offset을 검사한다. passive/declare에는 이 배치 검사가 없다.

**Maude — 번역식 초안**


```maude
eq Elemmode-ok(C:SpectecTerminal, PASSIVE, RT:SpectecTerminal) = true .
```


### 26.2. `Elemmode_ok/declare`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:82)

**SpecTec**


```spectec
rule Elemmode_ok/declare:
  C |- DECLARE : rt
```

**의미**

active element의 대상 table, 원소 subtype, offset을 검사한다. passive/declare에는 이 배치 검사가 없다.

**Maude — 번역식 초안**


```maude
eq Elemmode-ok(C:SpectecTerminal, DECLARE, RT:SpectecTerminal) = true .
```


### 26.3. `Elemmode_ok/active`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:85)

**SpecTec**


```spectec
rule Elemmode_ok/active:
  C |- ACTIVE x expr : rt
  -- if C.TABLES[x] = at lim rt'
  -- Reftype_sub: C |- rt <: rt'
  -- Expr_ok_const: C |- expr : at CONST
```

**의미**

active element의 대상 table, 원소 subtype, offset을 검사한다. passive/declare에는 이 배치 검사가 없다.

이 rule이 직접 호출하는 relation: `Expr_ok_const`, `Reftype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Elemmode-ok(C:SpectecTerminal, ACTIVE(X4:Nat, EXPR:InstrList), RT:SpectecTerminal) = true
  if tuple(AT:SpectecTerminal (LIM:SpectecTerminal RT-:SpectecTerminal)) := (C:SpectecTerminal . 'TABLES) [ X4:Nat ]
    /\ Reftype-sub(C:SpectecTerminal, RT:SpectecTerminal, RT-:SpectecTerminal)
    /\ Expr-ok-const(C:SpectecTerminal, EXPR:InstrList, AT:SpectecTerminal) .
```


<a id="expr-ok-const"></a>

## 27. `Expr_ok_const`

식의 결과 타입과 상수 식이라는 두 조건을 모두 확인한다.

**SpecTec 선언**


```spectec
relation Expr_ok_const: context |- expr : valtype CONST  hint(name "TC-expr") hint(macro "%exprokconst")
```

**Maude 선언**


```maude
op Expr-ok-const : SpectecTerminal InstrList SpectecTerminal ~> Bool .
```


### 27.1. `Expr_ok_const`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:699)

**SpecTec**


```spectec
rule Expr_ok_const:
  C |- expr : t CONST
  -- Expr_ok: C |- expr : t
  -- Expr_const: C |- expr CONST
```

**의미**

식의 결과 타입과 상수 식이라는 두 조건을 모두 확인한다.

이 rule이 직접 호출하는 relation: `Expr_const`, `Expr_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Expr-ok-const(C:SpectecTerminal, EXPR:InstrList, T:SpectecTerminal) = true
  if Expr-ok(C:SpectecTerminal, EXPR:InstrList, T:SpectecTerminal)
    /\ Expr-const(C:SpectecTerminal, EXPR:InstrList) .
```


<a id="externidx-ok"></a>

## 28. `Externidx_ok`

모듈 내부 번호가 가리키는 항목의 타입을 문맥에서 찾아 외부 타입 표시를 붙인다.

**SpecTec 선언**


```spectec
relation Externidx_ok: context |- externidx : externtype  hint(name "T-externidx") hint(macro "%externidx")
```

**Maude 선언**


```maude
op Externidx-ok : SpectecTerminal SpectecTerminal ~> SpectecTerminal .
```


### 28.1. `Externidx_ok/tag`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:111)

**SpecTec**


```spectec
rule Externidx_ok/tag:
  C |- TAG x : TAG jt
  -- if C.TAGS[x] = jt
```

**의미**

모듈 내부 번호가 가리키는 항목의 타입을 문맥에서 찾아 외부 타입 표시를 붙인다.

**Maude — 번역식 초안**


```maude
ceq Externidx-ok(C:SpectecTerminal, TAG(X4:Nat)) = TAG(JT:SpectecTerminal)
  if JT:SpectecTerminal := (C:SpectecTerminal . 'TAGS) [ X4:Nat ] .
```


### 28.2. `Externidx_ok/global`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:115)

**SpecTec**


```spectec
rule Externidx_ok/global:
  C |- GLOBAL x : GLOBAL gt
  -- if C.GLOBALS[x] = gt
```

**의미**

모듈 내부 번호가 가리키는 항목의 타입을 문맥에서 찾아 외부 타입 표시를 붙인다.

**Maude — 번역식 초안**


```maude
ceq Externidx-ok(C:SpectecTerminal, GLOBAL(X4:Nat)) = GLOBAL(GT2:SpectecTerminal)
  if GT2:SpectecTerminal := (C:SpectecTerminal . 'GLOBALS) [ X4:Nat ] .
```


### 28.3. `Externidx_ok/mem`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:119)

**SpecTec**


```spectec
rule Externidx_ok/mem:
  C |- MEM x : MEM mt
  -- if C.MEMS[x] = mt
```

**의미**

모듈 내부 번호가 가리키는 항목의 타입을 문맥에서 찾아 외부 타입 표시를 붙인다.

**Maude — 번역식 초안**


```maude
ceq Externidx-ok(C:SpectecTerminal, MEM(X4:Nat)) = MEM(MT:SpectecTerminal)
  if MT:SpectecTerminal := (C:SpectecTerminal . 'MEMS) [ X4:Nat ] .
```


### 28.4. `Externidx_ok/table`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:123)

**SpecTec**


```spectec
rule Externidx_ok/table:
  C |- TABLE x : TABLE tt
  -- if C.TABLES[x] = tt
```

**의미**

모듈 내부 번호가 가리키는 항목의 타입을 문맥에서 찾아 외부 타입 표시를 붙인다.

**Maude — 번역식 초안**


```maude
ceq Externidx-ok(C:SpectecTerminal, TABLE(X4:Nat)) = TABLE(TT:SpectecTerminal)
  if TT:SpectecTerminal := (C:SpectecTerminal . 'TABLES) [ X4:Nat ] .
```


### 28.5. `Externidx_ok/func`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:127)

**SpecTec**


```spectec
rule Externidx_ok/func:
  C |- FUNC x : FUNC dt
  -- if C.FUNCS[x] = dt
```

**의미**

모듈 내부 번호가 가리키는 항목의 타입을 문맥에서 찾아 외부 타입 표시를 붙인다.

**Maude — 번역식 초안**


```maude
ceq Externidx-ok(C:SpectecTerminal, FUNC(X4:Nat)) = FUNC(DT:SpectecTerminal)
  if DT:SpectecTerminal := (C:SpectecTerminal . 'FUNCS) [ X4:Nat ] .
```


<a id="expr-ok"></a>

## 29. `Expr_ok`

빈 operand stack에서 식을 실행하는 명령어 타입 유도가 요청 결과 리스트를 만드는지 검사한다.

**SpecTec 선언**


```spectec
relation Expr_ok: context |- expr : resulttype      hint(name "T-expr")   hint(macro "%expr")
```

**Maude 선언**


```maude
op Expr-ok : SpectecTerminal InstrList SpectecTerminals ~> Bool .
```


### 29.1. `Expr_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:638)

**SpecTec**


```spectec
rule Expr_ok:
  C |- instr* : t*
  -- Instrs_ok: C |- instr* : eps -> t*
```

**의미**

빈 operand stack에서 식을 실행하는 명령어 타입 유도가 요청 결과 리스트를 만드는지 검사한다.

이 rule이 직접 호출하는 relation: `Instrs_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Expr-ok(C:SpectecTerminal, INSTR-:InstrList, T-:SpectecTerminals) = true
  if Instrs-ok(C:SpectecTerminal, INSTR-:InstrList, eps ->- eps  T-:SpectecTerminals) .
```


<a id="local-ok"></a>

## 30. `Local_ok`

기본값을 만들 수 있는 local은 SET, 만들 수 없는 local은 UNSET 타입으로 정한다.

**SpecTec 선언**


```spectec
relation Local_ok: context |- local : localtype      hint(name "T-local")    hint(macro "%local")
```

**Maude 선언**


```maude
op Local-ok : SpectecTerminal SpectecTerminal ~> SpectecTerminal .
```


### 30.1. `Local_ok/set`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:46)

**SpecTec**


```spectec
rule Local_ok/set:
  C |- LOCAL t : SET t
  -- Defaultable: |- t DEFAULTABLE
```

**의미**

기본값이 있는 local 타입은 실행 전에 초기화할 수 있어 SET t로 인정한다.

이 rule이 직접 호출하는 relation: `Defaultable`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Local-ok(C:SpectecTerminal, LOCAL(T:SpectecTerminal)) = tuple(SET T:SpectecTerminal)
  if Defaultable(T:SpectecTerminal) .
```


### 30.2. `Local_ok/unset`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:50)

**SpecTec**


```spectec
rule Local_ok/unset:
  C |- LOCAL t : UNSET t
  -- Nondefaultable: |- t NONDEFAULTABLE
```

**의미**

기본값을 만들 수 없는 local 타입은 아직 초기화하지 않은 UNSET t로 인정한다.

이 rule이 직접 호출하는 relation: `Nondefaultable`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Local-ok(C:SpectecTerminal, LOCAL(T:SpectecTerminal)) = tuple(UNSET T:SpectecTerminal)
  if Nondefaultable(T:SpectecTerminal) .
```


<a id="global-ok"></a>

## 31. `Global_ok`

global 타입이 올바르고 초기화 식이 해당 값 타입의 상수 식인지 확인한다.

**SpecTec 선언**


```spectec
relation Global_ok: context |- global : globaltype   hint(name "T-global")   hint(macro "%global")
```

**Maude 선언**


```maude
op Global-ok : SpectecTerminal SpectecTerminal ~> SpectecTerminal .
```


### 31.1. `Global_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:30)

**SpecTec**


```spectec
rule Global_ok:
  C |- GLOBAL globaltype expr : globaltype
  -- Globaltype_ok: C |- globaltype : OK
  -- if globaltype = MUT? t
  -- Expr_ok_const: C |- expr : t CONST
```

**의미**

global 타입이 올바르고 초기화 식이 해당 값 타입의 상수 식인지 확인한다.

이 rule이 직접 호출하는 relation: `Expr_ok_const`, `Globaltype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Global-ok(C:SpectecTerminal, spectec-GLOBAL(tuple(seq(MUTS:SpectecTerminals) T:SpectecTerminal), E:InstrList)) = tuple(seq(MUTS:SpectecTerminals) T:SpectecTerminal)
  if typecheck(MUTS:SpectecTerminals, mut)
    /\ len(MUTS:SpectecTerminals) <= 1
    /\ Globaltype-ok(C:SpectecTerminal, tuple(seq(MUTS:SpectecTerminals) T:SpectecTerminal))
    /\ Expr-ok-const(C:SpectecTerminal, E:InstrList, T:SpectecTerminal) .
```


<a id="memtype-ok"></a>

## 32. `Memtype_ok`

주소 타입에 따른 memory 페이지 수 제한을 검사한다.

**SpecTec 선언**


```spectec
relation Memtype_ok: context |- memtype : OK        hint(name "K-mem")    hint(macro "%memtype")
```

**Maude 선언**


```maude
op Memtype-ok : SpectecTerminal SpectecTerminal ~> Bool .
```


### 32.1. `Memtype_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:228)

**SpecTec**


```spectec
rule Memtype_ok:
  C |- addrtype limits PAGE : OK
  -- Limits_ok: C |- limits : $(2^($size(addrtype) - 16))
```

**의미**

주소 타입에 따른 memory 페이지 수 제한을 검사한다.

이 rule이 직접 호출하는 relation: `Limits_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Memtype-ok(C:SpectecTerminal, __PAGE(ADDRTYPE:SpectecTerminal, LIMITS:SpectecTerminal)) = true
  if Limits-ok(C:SpectecTerminal, LIMITS:SpectecTerminal, 2 ^ (_-_(size(ADDRTYPE:SpectecTerminal) : nat <:> int, 16 : nat <:> int) : int <:> nat)) .
```


<a id="tabletype-ok"></a>

## 33. `Tabletype_ok`

table 주소 타입에 따른 크기 제한과 원소 참조 타입을 검사한다.

**SpecTec 선언**


```spectec
relation Tabletype_ok: context |- tabletype : OK    hint(name "K-table")  hint(macro "%tabletype")
```

**Maude 선언**


```maude
op Tabletype-ok : SpectecTerminal SpectecTerminal ~> Bool .
```


### 33.1. `Tabletype_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:232)

**SpecTec**


```spectec
rule Tabletype_ok:
  C |- addrtype limits reftype : OK
  -- Limits_ok: C |- limits : $(2^$size(addrtype) - 1)
  -- Reftype_ok: C |- reftype : OK
```

**의미**

table 주소 타입에 따른 크기 제한과 원소 참조 타입을 검사한다.

이 rule이 직접 호출하는 relation: `Limits_ok`, `Reftype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Tabletype-ok(C:SpectecTerminal, tuple(ADDRTYPE:SpectecTerminal (LIMITS:SpectecTerminal REFTYPE:SpectecTerminal))) = true
  if Limits-ok(C:SpectecTerminal, LIMITS:SpectecTerminal, _-_((2 ^ size(ADDRTYPE:SpectecTerminal)) : nat <:> int, 1 : nat <:> int) : int <:> nat)
    /\ Reftype-ok(C:SpectecTerminal, REFTYPE:SpectecTerminal) .
```


<a id="tagtype-ok"></a>

## 34. `Tagtype_ok`

tag가 사용하는 타입이 올바르며 FUNC 구성 타입으로 펼쳐지는지 확인한다.

**SpecTec 선언**


```spectec
relation Tagtype_ok: context |- tagtype : OK        hint(name "K-tag")    hint(macro "%tagtype")
```

**Maude 선언**


```maude
op Tagtype-ok : SpectecTerminal SpectecTerminal ~> Bool .
```


### 34.1. `Tagtype_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:219)

**SpecTec**


```spectec
rule Tagtype_ok:
  C |- typeuse : OK
  -- Typeuse_ok: C |- typeuse : OK
  -- Expand_use: typeuse ~~_C $($(FUNC t_1* -> t_2*))
```

**의미**

tag가 사용하는 타입이 올바르며 FUNC 구성 타입으로 펼쳐지는지 확인한다.

이 rule이 직접 호출하는 relation: `Expand_use`, `Typeuse_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Tagtype-ok(C:SpectecTerminal, TYPEUSE:SpectecTerminal) = true
  if Typeuse-ok(C:SpectecTerminal, TYPEUSE:SpectecTerminal)
    /\ FUNC T-1-:SpectecTerminals -> T-2-:SpectecTerminals := Expand-use(TYPEUSE:SpectecTerminal, C:SpectecTerminal) .
```


<a id="type-ok"></a>

## 35. `Type_ok`

재귀 타입 그룹을 현재 타입 번호 기준으로 닫고 각 subtype 정의를 검사한다.

**SpecTec 선언**


```spectec
relation Type_ok: context |- type : deftype*         hint(name "T-type")     hint(macro "%type")
```

**Maude 선언**


```maude
op Type-ok : SpectecTerminal SpectecTerminal ~> SpectecTerminals .
```


### 35.1. `Type_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.4-validation.modules.spectec:20)

**SpecTec**


```spectec
rule Type_ok:
  C |- TYPE rectype : dt*
  -- if x = |C.TYPES|
  -- if dt* = $rolldt(x, rectype)
  -- Rectype_ok: C ++ {TYPES dt*} |- rectype : OK(x)
```

**의미**

재귀 타입 그룹을 현재 타입 번호 기준으로 닫고 각 subtype 정의를 검사한다.

이 rule이 직접 호출하는 relation: `Rectype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Type-ok(C:SpectecTerminal, TYPE(RECTYPE:SpectecTerminal)) = DT-:SpectecTerminals
  if X4:Nat := len(C:SpectecTerminal . 'TYPES)
    /\ DT-:SpectecTerminals := rolldt(X4:Nat, RECTYPE:SpectecTerminal)
    /\ Rectype-ok(recordConcat(C:SpectecTerminal, { (field('TYPES, DT-:SpectecTerminals) ; (field('TAGS, eps) ; (field('GLOBALS, eps) ; (field('MEMS, eps) ; (field('TABLES, eps) ; (field('FUNCS, eps) ; (field('DATAS, eps) ; (field('ELEMS, eps) ; (field('LOCALS, eps) ; (field('LABELS, eps) ; (field('RETURN, eps) ; (field('REFS, eps) ; field('RECS, eps))))))))))))) }, context), RECTYPE:SpectecTerminal, spectec-OK(X4:Nat)) .
```


<a id="expand-use"></a>

## 36. `Expand_use`

정의 타입을 직접 펼치거나 문맥의 타입 번호를 찾아 펼친다.

**SpecTec 선언**


```spectec
relation Expand_use: typeuse ~~_context comptype  hint(macro "%expandyy") hint(tabular)
```

**Maude 선언**


```maude
op Expand-use : SpectecTerminal SpectecTerminal ~> SpectecTerminal .
```


### 36.1. `Expand_use/deftype`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:80)

**SpecTec**


```spectec
rule Expand_use/deftype: deftype ~~_C comptype       -- Expand: deftype ~~ comptype
```

**의미**

직접 준 정의 타입을 Expand에 넘겨 구성 타입을 얻는다.

이 rule이 직접 호출하는 relation: `Expand`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Expand-use(DEFTYPE:SpectecTerminal, C:SpectecTerminal) = COMPTYPE:SpectecTerminal
  if typecheck(DEFTYPE:SpectecTerminal, deftype)
    /\ COMPTYPE:SpectecTerminal := Expand(DEFTYPE:SpectecTerminal) .
```


### 36.2. `Expand_use/typeidx`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:81)

**SpecTec**


```spectec
rule Expand_use/typeidx: _IDX typeidx ~~_C comptype  -- Expand: C.TYPES[typeidx] ~~ comptype
```

**의미**

문맥 TYPES에서 해당 번호의 정의 타입을 찾고 Expand로 펼친다.

이 rule이 직접 호출하는 relation: `Expand`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Expand-use(-IDX(TYPEIDX:Nat), C:SpectecTerminal) = COMPTYPE:SpectecTerminal
  if COMPTYPE:SpectecTerminal := Expand((C:SpectecTerminal . 'TYPES) [ TYPEIDX:Nat ]) .
```


<a id="globaltype-ok"></a>

## 37. `Globaltype_ok`

MUT 표시의 유무와 관계없이 global의 값 타입이 올바른지 확인한다.

**SpecTec 선언**


```spectec
relation Globaltype_ok: context |- globaltype : OK  hint(name "K-global") hint(macro "%globaltype")
```

**Maude 선언**


```maude
op Globaltype-ok : SpectecTerminal SpectecTerminal ~> Bool .
```


### 37.1. `Globaltype_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:224)

**SpecTec**


```spectec
rule Globaltype_ok:
  C |- MUT? t : OK
  -- Valtype_ok: C |- t : OK
```

**의미**

MUT 표시의 유무와 관계없이 global의 값 타입이 올바른지 확인한다.

이 rule이 직접 호출하는 relation: `Valtype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Globaltype-ok(C:SpectecTerminal, tuple(seq(eps) T:SpectecTerminal)) = true
  if Valtype-ok(C:SpectecTerminal, T:SpectecTerminal) .
ceq Globaltype-ok(C:SpectecTerminal, tuple(seq(MUT ?) T:SpectecTerminal)) = true
  if Valtype-ok(C:SpectecTerminal, T:SpectecTerminal) .
```


<a id="typeuse-ok"></a>

## 38. `Typeuse_ok`

타입 번호·재귀 그룹 번호가 존재하는지, 또는 직접 준 정의 타입이 올바른지 확인한다.

**SpecTec 선언**


```spectec
relation Typeuse_ok: context |- typeuse : OK    hint(name "K-typeuse") hint(macro "%typeuse")
```

**Maude 선언**


```maude
op Typeuse-ok : SpectecTerminal SpectecTerminal ~> Bool .
```


### 38.1. `Typeuse_ok/typeidx`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:106)

**SpecTec**


```spectec
rule Typeuse_ok/typeidx:
  C |- _IDX typeidx : OK
  -- if C.TYPES[typeidx] = dt
```

**의미**

타입 번호·재귀 그룹 번호가 존재하는지, 또는 직접 준 정의 타입이 올바른지 확인한다.

**Maude — 번역식 초안**


```maude
ceq Typeuse-ok(C:SpectecTerminal, -IDX(TYPEIDX:Nat)) = true
  if DT:SpectecTerminal := (C:SpectecTerminal . 'TYPES) [ TYPEIDX:Nat ] .
```


### 38.2. `Typeuse_ok/rec`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:110)

**SpecTec**


```spectec
rule Typeuse_ok/rec:
  C |- REC i : OK
  -- if C.RECS[i] = st
```

**의미**

타입 번호·재귀 그룹 번호가 존재하는지, 또는 직접 준 정의 타입이 올바른지 확인한다.

**Maude — 번역식 초안**


```maude
ceq Typeuse-ok(C:SpectecTerminal, REC(I:Nat)) = true
  if ST2:SpectecTerminal := (C:SpectecTerminal . 'RECS) [ I:Nat ] .
```


### 38.3. `Typeuse_ok/deftype`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:114)

**SpecTec**


```spectec
rule Typeuse_ok/deftype:
  C |- deftype : OK
  -- Deftype_ok: C |- deftype : OK
```

**의미**

타입 번호·재귀 그룹 번호가 존재하는지, 또는 직접 준 정의 타입이 올바른지 확인한다.

이 rule이 직접 호출하는 relation: `Deftype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Typeuse-ok(C:SpectecTerminal, DEFTYPE:SpectecTerminal) = true
  if typecheck(DEFTYPE:SpectecTerminal, deftype)
    /\ Deftype-ok(C:SpectecTerminal, DEFTYPE:SpectecTerminal) .
```


<a id="deftype-sub"></a>

## 39. `Deftype_sub`

문맥으로 닫은 타입이 같거나 선언된 상위 타입 경로를 통해 도달하는지 판단한다.

**SpecTec 선언**


```spectec
relation Deftype_sub: context |- deftype <: deftype     hint(name "S-def")     hint(macro "%deftypematch")
```

**Maude 선언**


```maude
op Deftype-sub : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 39.1. `Deftype_sub/refl`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:195)

**SpecTec**


```spectec
rule Deftype_sub/refl:
  C |- deftype_1 <: deftype_2
  -- if $clos_deftype(C, deftype_1) = $clos_deftype(C, deftype_2)
```

**의미**

두 정의 타입을 현재 문맥으로 닫은 결과가 같으면 서로 맞는 타입으로 인정한다.

**Maude — 번역식 초안**


```maude
ceq Deftype-sub(C:SpectecTerminal, DEFTYPE-1:SpectecTerminal, DEFTYPE-2:SpectecTerminal) = true
  if clos-deftype(C:SpectecTerminal, DEFTYPE-1:SpectecTerminal) == clos-deftype(C:SpectecTerminal, DEFTYPE-2:SpectecTerminal) .
```


### 39.2. `Deftype_sub/super`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:199)

**SpecTec**


```spectec
rule Deftype_sub/super:
  C |- deftype_1 <: deftype_2
  -- if $unrolldt(deftype_1) = SUB final? typeuse* ct
  -- Heaptype_sub: C |- typeuse*[i] <: deftype_2
```

**의미**

첫 정의 타입을 펼친 뒤 선언된 상위 타입 중 하나를 골라 두 번째 정의 타입에 도달하는지 검사한다. 원본의 인덱스 i는 리스트 원소 선택을 위한 중간 값이다.

이 rule이 직접 호출하는 relation: `Heaptype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**

source의 리스트 인덱스 witness는 prefix/선택 원소/suffix의 associative matching으로 표현한다. 원문에서 선택 가능한 원소 전체를 유지한다.


```maude
ceq Deftype-sub(C:SpectecTerminal, D1:SpectecTerminal, D2:SpectecTerminal) = true
  if SUB(FIN:SpectecTerminals, TUS:SpectecTerminals, CT:SpectecTerminal) := unrolldt(D1:SpectecTerminal)
    /\ PREFIX:SpectecTerminals TU:SpectecTerminal SUFFIX:SpectecTerminals := TUS:SpectecTerminals
    /\ Heaptype-sub(C:SpectecTerminal, TU:SpectecTerminal, D2:SpectecTerminal) .
```


<a id="globaltype-sub"></a>

## 40. `Globaltype_sub`

읽기 전용 global은 값 타입의 subtype을 허용하고 수정 가능한 global은 양방향 일치를 요구한다.

**SpecTec 선언**


```spectec
relation Globaltype_sub: context |- globaltype <: globaltype hint(name "S-global") hint(macro "%globaltypematch")
```

**Maude 선언**


```maude
op Globaltype-sub : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 40.1. `Globaltype_sub/const`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:230)

**SpecTec**


```spectec
rule Globaltype_sub/const:
  C |- valtype_1 <: valtype_2
  -- Valtype_sub: C |- valtype_1 <: valtype_2
```

**의미**

읽기 전용 global은 값 타입의 subtype을 허용하고 수정 가능한 global은 양방향 일치를 요구한다.

이 rule이 직접 호출하는 relation: `Valtype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Globaltype-sub(C:SpectecTerminal, tuple(seq(eps) VALTYPE-1:SpectecTerminal), tuple(seq(eps) VALTYPE-22:SpectecTerminal)) = true
  if Valtype-sub(C:SpectecTerminal, VALTYPE-1:SpectecTerminal, VALTYPE-22:SpectecTerminal) .
```


### 40.2. `Globaltype_sub/var`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:234)

**SpecTec**


```spectec
rule Globaltype_sub/var:
  C |- MUT valtype_1 <: MUT valtype_2
  -- Valtype_sub: C |- valtype_1 <: valtype_2
  -- Valtype_sub: C |- valtype_2 <: valtype_1
```

**의미**

수정 가능한 global은 MUT 표시가 같고 값 타입이 양방향으로 맞아야 한다.

이 rule이 직접 호출하는 relation: `Valtype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Globaltype-sub(C:SpectecTerminal, tuple(seq(MUT ?) VALTYPE-1:SpectecTerminal), tuple(seq(MUT ?) VALTYPE-22:SpectecTerminal)) = true
  if Valtype-sub(C:SpectecTerminal, VALTYPE-1:SpectecTerminal, VALTYPE-22:SpectecTerminal)
    /\ Valtype-sub(C:SpectecTerminal, VALTYPE-22:SpectecTerminal, VALTYPE-1:SpectecTerminal) .
```


<a id="memtype-sub"></a>

## 41. `Memtype_sub`

주소 타입이 같은 두 memory의 크기 제한을 비교한다.

**SpecTec 선언**


```spectec
relation Memtype_sub: context |- memtype <: memtype          hint(name "S-mem")    hint(macro "%memtypematch")
```

**Maude 선언**


```maude
op Memtype-sub : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 41.1. `Memtype_sub`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:239)

**SpecTec**


```spectec
rule Memtype_sub:
  C |- addrtype limits_1 PAGE <: addrtype limits_2 PAGE
  -- Limits_sub: C |- limits_1 <: limits_2
```

**의미**

주소 타입이 같은 두 memory의 크기 제한을 비교한다.

이 rule이 직접 호출하는 relation: `Limits_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Memtype-sub(C:SpectecTerminal, __PAGE(ADDRTYPE:SpectecTerminal, LIMITS-1:SpectecTerminal), __PAGE(ADDRTYPE:SpectecTerminal, LIMITS-2:SpectecTerminal)) = true
  if Limits-sub(C:SpectecTerminal, LIMITS-1:SpectecTerminal, LIMITS-2:SpectecTerminal) .
```


<a id="tabletype-sub"></a>

## 42. `Tabletype_sub`

주소 타입이 같고 제한이 맞으며 원소 참조 타입이 양방향으로 맞는지 확인한다.

**SpecTec 선언**


```spectec
relation Tabletype_sub: context |- tabletype <: tabletype    hint(name "S-table")  hint(macro "%tabletypematch")
```

**Maude 선언**


```maude
op Tabletype-sub : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 42.1. `Tabletype_sub`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:243)

**SpecTec**


```spectec
rule Tabletype_sub:
  C |- addrtype limits_1 reftype_1 <: addrtype limits_2 reftype_2
  -- Limits_sub: C |- limits_1 <: limits_2
  -- Reftype_sub: C |- reftype_1 <: reftype_2
  -- Reftype_sub: C |- reftype_2 <: reftype_1
```

**의미**

table은 원소를 읽고 쓸 수 있어 원소 참조 타입을 양방향으로 비교한다. 크기 제한도 비교한다.

이 rule이 직접 호출하는 relation: `Limits_sub`, `Reftype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Tabletype-sub(C:SpectecTerminal, tuple(ADDRTYPE:SpectecTerminal (LIMITS-1:SpectecTerminal REFTYPE-1:SpectecTerminal)), tuple(ADDRTYPE:SpectecTerminal (LIMITS-2:SpectecTerminal REFTYPE-2:SpectecTerminal))) = true
  if Limits-sub(C:SpectecTerminal, LIMITS-1:SpectecTerminal, LIMITS-2:SpectecTerminal)
    /\ Reftype-sub(C:SpectecTerminal, REFTYPE-1:SpectecTerminal, REFTYPE-2:SpectecTerminal)
    /\ Reftype-sub(C:SpectecTerminal, REFTYPE-2:SpectecTerminal, REFTYPE-1:SpectecTerminal) .
```


<a id="tagtype-sub"></a>

## 43. `Tagtype_sub`

tag 함수 정의 타입이 서로 양방향으로 맞는지 확인한다.

**SpecTec 선언**


```spectec
relation Tagtype_sub: context |- tagtype <: tagtype          hint(name "S-tag")    hint(macro "%tagtypematch")
```

**Maude 선언**


```maude
op Tagtype-sub : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 43.1. `Tagtype_sub`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:225)

**SpecTec**


```spectec
rule Tagtype_sub:
  C |- deftype_1 <: deftype_2
  -- Deftype_sub: C |- deftype_1 <: deftype_2
  -- Deftype_sub: C |- deftype_2 <: deftype_1
```

**의미**

tag 함수 정의 타입이 서로 양방향으로 맞는지 확인한다.

이 rule이 직접 호출하는 relation: `Deftype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Tagtype-sub(C:SpectecTerminal, DEFTYPE-1:SpectecTerminal, DEFTYPE-2:SpectecTerminal) = true
  if typecheck(DEFTYPE-1:SpectecTerminal, deftype)
    /\ typecheck(DEFTYPE-2:SpectecTerminal, deftype)
    /\ Deftype-sub(C:SpectecTerminal, DEFTYPE-1:SpectecTerminal, DEFTYPE-2:SpectecTerminal)
    /\ Deftype-sub(C:SpectecTerminal, DEFTYPE-2:SpectecTerminal, DEFTYPE-1:SpectecTerminal) .
```


<a id="expr-const"></a>

## 44. `Expr_const`

식의 모든 명령어가 상수 식에 허용되는 명령어인지 확인한다.

**SpecTec 선언**


```spectec
relation Expr_const: context |- expr CONST               hint(name "C-expr")  hint(macro "%exprconst")
```

**Maude 선언**


```maude
op Expr-const : SpectecTerminal InstrList ~> Bool .
```


### 44.1. `Expr_const`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:695)

**SpecTec**


```spectec
rule Expr_const: C |- instr* CONST
  -- (Instr_const: C |- instr CONST)*
```

**의미**

식의 모든 명령어가 상수 식에 허용되는 명령어인지 확인한다.

이 rule이 직접 호출하는 relation: `Instr_const`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Expr-const(C:SpectecTerminal, INSTR-:InstrList) = true
  if iterpr-22(C:SpectecTerminal, INSTR-:InstrList) .
```


<a id="instrs-ok"></a>

## 45. `Instrs_ok`

명령어 리스트의 입력·결과 stack 타입과 local 초기화 정보를 유도한다.

**SpecTec 선언**


```spectec
relation Instrs_ok: context |- instr* : instrtype   hint(name "T-instr*") hint(macro "%instrs")
```

**Maude 선언**


```maude
op Instrs-ok : SpectecTerminal InstrList SpectecTerminal ~> Bool .
```


### 45.1. `Instrs_ok/empty`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:613)

**SpecTec**


```spectec
rule Instrs_ok/empty:
  C |- eps : eps -> eps
```

**의미**

빈 명령어 리스트는 빈 stack을 그대로 두고 local 초기화 효과도 없다.

**Maude — 번역식 초안**


```maude
eq Instrs-ok(C:SpectecTerminal, eps, eps ->- eps  eps) = true .
```


### 45.2. `Instrs_ok/seq`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:617)

**SpecTec**


```spectec
rule Instrs_ok/seq:
  C |- instr_1 instr_2* : t_1* ->_(x_1* x_2*) t_3*
  -- Instr_ok: C |- instr_1 : t_1* ->_(x_1*) t_2*
  -- (if C.LOCALS[x_1] = init t)*
  -- Instrs_ok: $with_locals(C, x_1*, (SET t)*) |- instr_2* : t_2* ->_(x_2*) t_3*
```

**의미**

첫 명령어가 만든 중간 stack 타입을 다음 명령어 리스트의 입력으로 연결한다. 첫 명령어가 초기화한 local은 다음 검사에서 SET으로 바꾼다.

이 rule이 직접 호출하는 relation: `Instr_ok`, `Instrs_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 추가 입력을 받은 조건 검사식. 원래 호출에 대한 완성된 판정기는 아님.**


```maude
op Instrs-ok-via-seq : SpectecTerminal InstrList SpectecTerminal SpectecTerminals ~> Bool .
ceq Instrs-ok-via-seq(C:SpectecTerminal, I:instr IS:InstrList, T1:SpectecTerminals ->- (X1:SpectecTerminals X2:SpectecTerminals) T3:SpectecTerminals, MID:SpectecTerminals) = true
  if Instr-ok(C:SpectecTerminal, I:instr, T1:SpectecTerminals ->- X1:SpectecTerminals MID:SpectecTerminals)
    /\ TS:SpectecTerminals := local-value-types(C:SpectecTerminal, X1:SpectecTerminals)
    /\ Instrs-ok(with-locals(C:SpectecTerminal, X1:SpectecTerminals, set-types(TS:SpectecTerminals)), IS:InstrList, MID:SpectecTerminals ->- X2:SpectecTerminals T3:SpectecTerminals) .
```


### 45.3. `Instrs_ok/sub`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:623)

**SpecTec**


```spectec
rule Instrs_ok/sub:
  C |- instr* : it'
  -- Instrs_ok: C |- instr* : it
  -- Instrtype_sub: C |- it <: it'
  -- Instrtype_ok: C |- it' : OK
```

**의미**

같은 명령어 리스트에 이미 유도된 instruction type it가 있으면, it <: it'이고 it'가 올바를 때 it'로도 인정한다.

이 rule이 직접 호출하는 relation: `Instrs_ok`, `Instrtype_ok`, `Instrtype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 추가 입력을 받은 조건 검사식. 원래 호출에 대한 완성된 판정기는 아님.**


```maude
op Instrs-ok-via-sub : SpectecTerminal InstrList SpectecTerminal SpectecTerminal ~> Bool .
ceq Instrs-ok-via-sub(C:SpectecTerminal, IS:InstrList, TARGET:SpectecTerminal, PRIOR:SpectecTerminal) = true
  if Instrs-ok(C:SpectecTerminal, IS:InstrList, PRIOR:SpectecTerminal)
    /\ Instrtype-sub(C:SpectecTerminal, PRIOR:SpectecTerminal, TARGET:SpectecTerminal)
    /\ Instrtype-ok(C:SpectecTerminal, TARGET:SpectecTerminal) .
```


### 45.4. `Instrs_ok/frame`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:630)

**SpecTec**


```spectec
rule Instrs_ok/frame:
  C |- instr* : (t* t_1*) ->_(x*) (t* t_2*)
  -- Instrs_ok: C |- instr* : t_1* ->_(x*) t_2*
  -- Resulttype_ok: C |- t* : OK
```

**의미**

명령어가 사용하지 않는 stack 타입 prefix t*를 입력과 출력 양쪽에 그대로 붙일 수 있다.

이 rule이 직접 호출하는 relation: `Instrs_ok`, `Resulttype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instrs-ok(C:SpectecTerminal, INSTR-:InstrList, (T-:SpectecTerminals T-1-:SpectecTerminals) ->- X-2:SpectecTerminals  (T-:SpectecTerminals T-2-:SpectecTerminals)) = true
  if Instrs-ok(C:SpectecTerminal, INSTR-:InstrList, T-1-:SpectecTerminals ->- X-2:SpectecTerminals  T-2-:SpectecTerminals)
    /\ Resulttype-ok(C:SpectecTerminal, T-:SpectecTerminals) .
```


<a id="defaultable"></a>

## 46. `Defaultable`

해당 값 타입의 기본값을 만들 수 있는지 확인한다.

**SpecTec 선언**


```spectec
relation Defaultable: |- valtype DEFAULTABLE  hint(show $default_(%2) =/= eps)
```

**Maude 선언**


```maude
op Defaultable : SpectecTerminal ~> Bool .
```


### 46.1. `Defaultable`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:15)

**SpecTec**


```spectec
rule Defaultable: |- t DEFAULTABLE -- if $default_(t) =/= eps
```

**의미**

해당 값 타입의 기본값을 만들 수 있는지 확인한다.

**Maude — 번역식 초안**


```maude
ceq Defaultable(T:SpectecTerminal) = true
  if default-(T:SpectecTerminal) =/= eps .
```


<a id="nondefaultable"></a>

## 47. `Nondefaultable`

해당 값 타입의 기본값을 만들 수 없는지 확인한다.

**SpecTec 선언**


```spectec
relation Nondefaultable: |- valtype NONDEFAULTABLE  hint(show $default_(%2) = eps)
```

**Maude 선언**


```maude
op Nondefaultable : SpectecTerminal ~> Bool .
```


### 47.1. `Nondefaultable`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/4.1-execution.values.spectec:18)

**SpecTec**


```spectec
rule Nondefaultable: |- t NONDEFAULTABLE -- if $default_(t) = eps
```

**의미**

해당 값 타입의 기본값을 만들 수 없는지 확인한다.

**Maude — 번역식 초안**


```maude
ceq Nondefaultable(T:SpectecTerminal) = true
  if default-(T:SpectecTerminal) == eps .
```


<a id="limits-ok"></a>

## 48. `Limits_ok`

최솟값과 선택적인 최댓값이 허용 상한 이내인지 확인한다.

**SpecTec 선언**


```spectec
relation Limits_ok: context |- limits : nat         hint(name "K-limits") hint(macro "%limits")  hint(prosepp "within")
```

**Maude 선언**


```maude
op Limits-ok : SpectecTerminal SpectecTerminal Nat ~> Bool .
```


### 48.1. `Limits_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:214)

**SpecTec**


```spectec
rule Limits_ok:
  C |- `[n .. m?] : k
  -- if n <= k
  -- (if n <= m <= k)?
```

**의미**

최솟값과 선택적인 최댓값이 허용 상한 이내인지 확인한다.

**Maude — 번역식 초안**


```maude
ceq Limits-ok(C:SpectecTerminal, [ N3:Nat .. M-:SpectecTerminals ], K3:Nat) = true
  if len(M-:SpectecTerminals) <= 1
    /\ N3:Nat <= K3:Nat
    /\ iterpr-13(N3:Nat, K3:Nat, M-:SpectecTerminals) .
```


<a id="rectype-ok"></a>

## 49. `Rectype_ok`

재귀 타입 그룹의 subtype들을 지정한 시작 타입 번호부터 순서대로 검사한다.

**SpecTec 선언**


```spectec
relation Rectype_ok: context |- rectype : oktypeidx     hint(name "K-rect")    hint(macro "%rectype")     hint(prosepp "for")
```

**Maude 선언**


```maude
op Rectype-ok : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 49.1. `Rectype_ok/empty`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:179)

**SpecTec**


```spectec
rule Rectype_ok/empty:
  C |- REC eps : OK(x)
```

**의미**

빈 재귀 그룹은 검사할 subtype이 없어 현재 시작 번호에서 성공한다.

**Maude — 번역식 초안**


```maude
eq Rectype-ok(C:SpectecTerminal, REC(eps), spectec-OK(X4:Nat)) = true .
```


### 49.2. `Rectype_ok/cons`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:182)

**SpecTec**


```spectec
rule Rectype_ok/cons:
  C |- REC (subtype_1 subtype*) : OK(x)
  -- Subtype_ok: C |- subtype_1 : OK(x)
  -- Rectype_ok: C |- REC subtype* : OK($(x+1))
```

**의미**

첫 subtype은 시작 번호 x에서, 나머지는 x+1에서 검사한다.

이 rule이 직접 호출하는 relation: `Rectype_ok`, `Subtype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Rectype-ok(C:SpectecTerminal, REC(SUBTYPE-1:SpectecTerminal SUBTYPE-:SpectecTerminals), spectec-OK(X4:Nat)) = true
  if Subtype-ok(C:SpectecTerminal, SUBTYPE-1:SpectecTerminal, spectec-OK(X4:Nat))
    /\ Rectype-ok(C:SpectecTerminal, REC(SUBTYPE-:SpectecTerminals), spectec-OK(X4:Nat + 1)) .
```


<a id="valtype-ok"></a>

## 50. `Valtype_ok`

숫자·벡터·참조 타입 또는 BOT가 올바른 값 타입인지 확인한다.

**SpecTec 선언**


```spectec
relation Valtype_ok: context |- valtype : OK    hint(name "K-val")  hint(macro "%valtype")
```

**Maude 선언**


```maude
op Valtype-ok : SpectecTerminal SpectecTerminal ~> Bool .
```


### 50.1. `Valtype_ok/num`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:34)

**SpecTec**


```spectec
rule Valtype_ok/num:
  C |- numtype : OK
  -- Numtype_ok: C |- numtype : OK
```

**의미**

숫자·벡터·참조 타입 또는 BOT가 올바른 값 타입인지 확인한다. 이 rule은 `num` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

이 rule이 직접 호출하는 relation: `Numtype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Valtype-ok(C:SpectecTerminal, NUMTYPE:SpectecTerminal) = true
  if typecheck(NUMTYPE:SpectecTerminal, numtype)
    /\ Numtype-ok(C:SpectecTerminal, NUMTYPE:SpectecTerminal) .
```


### 50.2. `Valtype_ok/vec`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:38)

**SpecTec**


```spectec
rule Valtype_ok/vec:
  C |- vectype : OK
  -- Vectype_ok: C |- vectype : OK
```

**의미**

숫자·벡터·참조 타입 또는 BOT가 올바른 값 타입인지 확인한다. 이 rule은 `vec` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

이 rule이 직접 호출하는 relation: `Vectype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Valtype-ok(C:SpectecTerminal, VECTYPE:SpectecTerminal) = true
  if typecheck(VECTYPE:SpectecTerminal, vectype)
    /\ Vectype-ok(C:SpectecTerminal, VECTYPE:SpectecTerminal) .
```


### 50.3. `Valtype_ok/ref`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:42)

**SpecTec**


```spectec
rule Valtype_ok/ref:
  C |- reftype : OK
  -- Reftype_ok: C |- reftype : OK
```

**의미**

숫자·벡터·참조 타입 또는 BOT가 올바른 값 타입인지 확인한다. 이 rule은 `ref` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

이 rule이 직접 호출하는 relation: `Reftype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Valtype-ok(C:SpectecTerminal, REFTYPE:SpectecTerminal) = true
  if typecheck(REFTYPE:SpectecTerminal, reftype)
    /\ Reftype-ok(C:SpectecTerminal, REFTYPE:SpectecTerminal) .
```


### 50.4. `Valtype_ok/bot`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:46)

**SpecTec**


```spectec
rule Valtype_ok/bot:
  C |- BOT : OK
```

**의미**

숫자·벡터·참조 타입 또는 BOT가 올바른 값 타입인지 확인한다. 이 rule은 `bot` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

**Maude — 번역식 초안**


```maude
eq Valtype-ok(C:SpectecTerminal, BOT) = true .
```


<a id="deftype-ok"></a>

## 51. `Deftype_ok`

정의 타입의 재귀 그룹이 올바르고 그룹 내부 번호가 범위 안인지 확인한다.

**SpecTec 선언**


```spectec
relation Deftype_ok: context |- deftype : OK            hint(name "K-def")     hint(macro "%deftype")
```

**Maude 선언**


```maude
op Deftype-ok : SpectecTerminal SpectecTerminal ~> Bool .
```


### 51.1. `Deftype_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:197)

**SpecTec**


```spectec
rule Deftype_ok:
  C |- _DEF rectype i : OK
  -- Rectype_ok2: C, RECS subtype^n |- rectype : OK(0)
  -- if rectype = REC subtype^n
  -- if i < n
```

**의미**

정의 타입의 재귀 그룹이 올바르고 그룹 내부 번호가 범위 안인지 확인한다.

이 rule이 직접 호출하는 relation: `Rectype_ok2`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**

실행 가능한 바인딩을 위해 REC 구조와 그룹 길이를 먼저 읽었다. 원문의 논리적 조건은 유지하되 검사 실행 순서를 조정한 설계다. 일반 자동화에서 임의 premise 재정렬을 허용한다는 뜻은 아니다.


```maude
ceq Deftype-ok(C:SpectecTerminal, -DEF(RT:SpectecTerminal, I:Nat)) = true
  if REC(STS:SpectecTerminals) := RT:SpectecTerminal
    /\ I:Nat < len(STS:SpectecTerminals)
    /\ Rectype-ok2(recordConcat(rec-context(STS:SpectecTerminals), C:SpectecTerminal, context), RT:SpectecTerminal, spectec-OK(0)) .
```


<a id="valtype-sub"></a>

## 52. `Valtype_sub`

숫자·벡터는 동일 종류, 참조는 참조 subtype 규칙, BOT는 모든 값 타입으로 인정한다.

**SpecTec 선언**


```spectec
relation Valtype_sub: context |- valtype <: valtype    hint(name "S-val")  hint(macro "%valtypematch")
```

**Maude 선언**


```maude
op Valtype-sub : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 52.1. `Valtype_sub/num`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:114)

**SpecTec**


```spectec
rule Valtype_sub/num:
  C |- numtype_1 <: numtype_2
  -- Numtype_sub: C |- numtype_1 <: numtype_2
```

**의미**

숫자·벡터는 동일 종류, 참조는 참조 subtype 규칙, BOT는 모든 값 타입으로 인정한다. 이 rule은 `num` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

이 rule이 직접 호출하는 relation: `Numtype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Valtype-sub(C:SpectecTerminal, NUMTYPE-1:SpectecTerminal, NUMTYPE-2:SpectecTerminal) = true
  if typecheck(NUMTYPE-1:SpectecTerminal, numtype)
    /\ typecheck(NUMTYPE-2:SpectecTerminal, numtype)
    /\ Numtype-sub(C:SpectecTerminal, NUMTYPE-1:SpectecTerminal, NUMTYPE-2:SpectecTerminal) .
```


### 52.2. `Valtype_sub/vec`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:118)

**SpecTec**


```spectec
rule Valtype_sub/vec:
  C |- vectype_1 <: vectype_2
  -- Vectype_sub: C |- vectype_1 <: vectype_2
```

**의미**

숫자·벡터는 동일 종류, 참조는 참조 subtype 규칙, BOT는 모든 값 타입으로 인정한다. 이 rule은 `vec` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

이 rule이 직접 호출하는 relation: `Vectype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Valtype-sub(C:SpectecTerminal, VECTYPE-1:SpectecTerminal, VECTYPE-2:SpectecTerminal) = true
  if typecheck(VECTYPE-1:SpectecTerminal, vectype)
    /\ typecheck(VECTYPE-2:SpectecTerminal, vectype)
    /\ Vectype-sub(C:SpectecTerminal, VECTYPE-1:SpectecTerminal, VECTYPE-2:SpectecTerminal) .
```


### 52.3. `Valtype_sub/ref`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:122)

**SpecTec**


```spectec
rule Valtype_sub/ref:
  C |- reftype_1 <: reftype_2
  -- Reftype_sub: C |- reftype_1 <: reftype_2
```

**의미**

숫자·벡터는 동일 종류, 참조는 참조 subtype 규칙, BOT는 모든 값 타입으로 인정한다. 이 rule은 `ref` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

이 rule이 직접 호출하는 relation: `Reftype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Valtype-sub(C:SpectecTerminal, REFTYPE-1:SpectecTerminal, REFTYPE-2:SpectecTerminal) = true
  if typecheck(REFTYPE-1:SpectecTerminal, reftype)
    /\ typecheck(REFTYPE-2:SpectecTerminal, reftype)
    /\ Reftype-sub(C:SpectecTerminal, REFTYPE-1:SpectecTerminal, REFTYPE-2:SpectecTerminal) .
```


### 52.4. `Valtype_sub/bot`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:126)

**SpecTec**


```spectec
rule Valtype_sub/bot:
  C |- BOT <: valtype
```

**의미**

숫자·벡터는 동일 종류, 참조는 참조 subtype 규칙, BOT는 모든 값 타입으로 인정한다. 이 rule은 `bot` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

**Maude — 번역식 초안**


```maude
eq Valtype-sub(C:SpectecTerminal, BOT, VALTYPE:SpectecTerminal) = true .
```


<a id="limits-sub"></a>

## 53. `Limits_sub`

제공하는 최솟값이 요구 최솟값 이상이며 필요한 최대 제한을 만족하는지 확인한다.

**SpecTec 선언**


```spectec
relation Limits_sub: context |- limits <: limits             hint(name "S-limits") hint(macro "%limitsmatch")
```

**Maude 선언**


```maude
op Limits-sub : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 53.1. `Limits_sub/max`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:215)

**SpecTec**


```spectec
rule Limits_sub/max:
  C |- `[n_1 .. m_1] <: `[n_2 .. m_2?]
  -- if n_1 >= n_2
  -- (if m_1 <= m_2)?
```

**의미**

제공 최소 크기는 요구 최소 크기 이상이어야 하고, 요구 최대 크기가 있으면 제공 최대 크기는 그 이하이어야 한다.

**Maude — 번역식 초안**


```maude
ceq Limits-sub(C:SpectecTerminal, [ N-1:Nat .. (M-12:Nat ?) ], [ N-22:Nat .. M-2-:SpectecTerminals ]) = true
  if len(M-2-:SpectecTerminals) <= 1
    /\ N-1:Nat >= N-22:Nat
    /\ iterpr-15(M-12:Nat, M-2-:SpectecTerminals) .
```


### 53.2. `Limits_sub/eps`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:220)

**SpecTec**


```spectec
rule Limits_sub/eps:
  C |- `[n_1 .. eps] <: `[n_2 .. eps]
  -- if n_1 >= n_2
```

**의미**

양쪽 모두 최대 크기 제한이 없으면 최소 크기만 비교한다.

**Maude — 번역식 초안**


```maude
ceq Limits-sub(C:SpectecTerminal, [ N-1:Nat .. eps ], [ N-22:Nat .. eps ]) = true
  if N-1:Nat >= N-22:Nat .
```


<a id="instr-const"></a>

## 54. `Instr_const`

이 명령어를 상수 식에 사용할 수 있는지 판단한다. 일반 실행 결과를 계산하는 규칙은 아니다.

**SpecTec 선언**


```spectec
relation Instr_const: context |- instr CONST             hint(name "C-instr") hint(macro "%instrconst")
```

**Maude 선언**


```maude
op Instr-const : SpectecTerminal instr ~> Bool .
```


### 54.1. `Instr_const/const`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:649)

**SpecTec**


```spectec
rule Instr_const/const:
  C |- (CONST nt c_nt) CONST
```

**의미**

`const` 형태의 명령어를 상수 식에서 사용할 수 있는 명령어로 인정한다. 아래 결론의 정확한 operand 패턴을 따른다.

**Maude — 번역식 초안**


```maude
eq Instr-const(C:SpectecTerminal, CONST(NT:SpectecTerminal, C-NT:SpectecTerminal)) = true .
```


### 54.2. `Instr_const/vconst`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:652)

**SpecTec**


```spectec
rule Instr_const/vconst:
  C |- (VCONST vt c_vt) CONST
```

**의미**

`vconst` 형태의 명령어를 상수 식에서 사용할 수 있는 명령어로 인정한다. 아래 결론의 정확한 operand 패턴을 따른다.

**Maude — 번역식 초안**


```maude
eq Instr-const(C:SpectecTerminal, VCONST(VT:SpectecTerminal, C-VT:Nat)) = true .
```


### 54.3. `Instr_const/ref.null`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:655)

**SpecTec**


```spectec
rule Instr_const/ref.null:
  C |- (REF.NULL ht) CONST
```

**의미**

`ref.null` 형태의 명령어를 상수 식에서 사용할 수 있는 명령어로 인정한다. 아래 결론의 정확한 operand 패턴을 따른다.

**Maude — 번역식 초안**


```maude
eq Instr-const(C:SpectecTerminal, REF.NULL(HT:SpectecTerminal)) = true .
```


### 54.4. `Instr_const/ref.i31`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:658)

**SpecTec**


```spectec
rule Instr_const/ref.i31:
  C |- (REF.I31) CONST
```

**의미**

`ref.i31` 형태의 명령어를 상수 식에서 사용할 수 있는 명령어로 인정한다. 아래 결론의 정확한 operand 패턴을 따른다.

**Maude — 번역식 초안**


```maude
eq Instr-const(C:SpectecTerminal, REF.I31) = true .
```


### 54.5. `Instr_const/ref.func`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:661)

**SpecTec**


```spectec
rule Instr_const/ref.func:
  C |- (REF.FUNC x) CONST
```

**의미**

`ref.func` 형태의 명령어를 상수 식에서 사용할 수 있는 명령어로 인정한다. 아래 결론의 정확한 operand 패턴을 따른다.

**Maude — 번역식 초안**


```maude
eq Instr-const(C:SpectecTerminal, REF.FUNC(X4:Nat)) = true .
```


### 54.6. `Instr_const/struct.new`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:664)

**SpecTec**


```spectec
rule Instr_const/struct.new:
  C |- (STRUCT.NEW x) CONST
```

**의미**

`struct.new` 형태의 명령어를 상수 식에서 사용할 수 있는 명령어로 인정한다. 아래 결론의 정확한 operand 패턴을 따른다.

**Maude — 번역식 초안**


```maude
eq Instr-const(C:SpectecTerminal, STRUCT.NEW(X4:Nat)) = true .
```


### 54.7. `Instr_const/struct.new_default`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:667)

**SpecTec**


```spectec
rule Instr_const/struct.new_default:
  C |- (STRUCT.NEW_DEFAULT x) CONST
```

**의미**

`struct.new_default` 형태의 명령어를 상수 식에서 사용할 수 있는 명령어로 인정한다. 아래 결론의 정확한 operand 패턴을 따른다.

**Maude — 번역식 초안**


```maude
eq Instr-const(C:SpectecTerminal, STRUCT.NEW-DEFAULT(X4:Nat)) = true .
```


### 54.8. `Instr_const/array.new`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:670)

**SpecTec**


```spectec
rule Instr_const/array.new:
  C |- (ARRAY.NEW x) CONST
```

**의미**

`array.new` 형태의 명령어를 상수 식에서 사용할 수 있는 명령어로 인정한다. 아래 결론의 정확한 operand 패턴을 따른다.

**Maude — 번역식 초안**


```maude
eq Instr-const(C:SpectecTerminal, ARRAY.NEW(X4:Nat)) = true .
```


### 54.9. `Instr_const/array.new_default`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:673)

**SpecTec**


```spectec
rule Instr_const/array.new_default:
  C |- (ARRAY.NEW_DEFAULT x) CONST
```

**의미**

`array.new_default` 형태의 명령어를 상수 식에서 사용할 수 있는 명령어로 인정한다. 아래 결론의 정확한 operand 패턴을 따른다.

**Maude — 번역식 초안**


```maude
eq Instr-const(C:SpectecTerminal, ARRAY.NEW-DEFAULT(X4:Nat)) = true .
```


### 54.10. `Instr_const/array.new_fixed`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:676)

**SpecTec**


```spectec
rule Instr_const/array.new_fixed:
  C |- (ARRAY.NEW_FIXED x n) CONST
```

**의미**

`array.new_fixed` 형태의 명령어를 상수 식에서 사용할 수 있는 명령어로 인정한다. 아래 결론의 정확한 operand 패턴을 따른다.

**Maude — 번역식 초안**


```maude
eq Instr-const(C:SpectecTerminal, ARRAY.NEW-FIXED(X4:Nat, N3:Nat)) = true .
```


### 54.11. `Instr_const/any.convert_extern`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:679)

**SpecTec**


```spectec
rule Instr_const/any.convert_extern:
  C |- (ANY.CONVERT_EXTERN) CONST
```

**의미**

`any.convert_extern` 형태의 명령어를 상수 식에서 사용할 수 있는 명령어로 인정한다. 아래 결론의 정확한 operand 패턴을 따른다.

**Maude — 번역식 초안**


```maude
eq Instr-const(C:SpectecTerminal, ANY.CONVERT-EXTERN) = true .
```


### 54.12. `Instr_const/extern.convert_any`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:682)

**SpecTec**


```spectec
rule Instr_const/extern.convert_any:
  C |- (EXTERN.CONVERT_ANY) CONST
```

**의미**

`extern.convert_any` 형태의 명령어를 상수 식에서 사용할 수 있는 명령어로 인정한다. 아래 결론의 정확한 operand 패턴을 따른다.

**Maude — 번역식 초안**


```maude
eq Instr-const(C:SpectecTerminal, EXTERN.CONVERT-ANY) = true .
```


### 54.13. `Instr_const/global.get`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:685)

**SpecTec**


```spectec
rule Instr_const/global.get:
  C |- (GLOBAL.GET x) CONST
  -- if C.GLOBALS[x] = t
```

**의미**

global.get은 읽기 전용 global의 값을 읽는 경우에 상수 식 명령어로 인정한다. source의 C.GLOBALS[x] = t 패턴에는 MUT 표시가 없다.

**Maude — 번역식 초안**


```maude
ceq Instr-const(C:SpectecTerminal, GLOBAL.GET(X4:Nat)) = true
  if tuple(seq(eps) T:SpectecTerminal) := (C:SpectecTerminal . 'GLOBALS) [ X4:Nat ] .
```


### 54.14. `Instr_const/binop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:689)

**SpecTec**


```spectec
rule Instr_const/binop:
  C |- (BINOP Inn binop) CONST
  -- if Inn <- I32 I64
  -- if binop <- ADD SUB MUL
```

**의미**

I32/I64의 ADD/SUB/MUL만 이 상수 식 이항 연산 규칙으로 인정한다.

**Maude — 번역식 초안**


```maude
ceq Instr-const(C:SpectecTerminal, BINOP(INN:SpectecTerminal, BINOP2:SpectecTerminal)) = true
  if typecheck(INN:SpectecTerminal, addrtype)
    /\ INN:SpectecTerminal <- (I32 I64)
    /\ BINOP2:SpectecTerminal <- (ADD (spectec-SUB MUL)) .
```


<a id="instr-ok"></a>

## 55. `Instr_ok`

한 명령어의 입력 operand stack 타입, 결과 타입, local 초기화 효과를 검사한다.

**SpecTec 선언**


```spectec
relation Instr_ok: context |- instr : instrtype     hint(name "T-instr")  hint(macro "%instr")
```

**Maude 선언**


```maude
op Instr-ok : SpectecTerminal instr SpectecTerminal ~> Bool .
```


### 55.1. `Instr_ok/nop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:18)

**SpecTec**


```spectec
rule Instr_ok/nop:
  C |- NOP : eps -> eps
```

**의미**

NOP는 operand stack을 바꾸지 않는다.

정확한 stack 변화는 결론의 `eps -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, NOP, eps ->- eps  eps) = true .
```


### 55.2. `Instr_ok/unreachable`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:21)

**SpecTec**


```spectec
rule Instr_ok/unreachable:
  C |- UNREACHABLE : t_1* -> t_2*
  -- Instrtype_ok: C |- t_1* -> t_2* : OK
```

**의미**

UNREACHABLE은 도달할 수 없는 뒤쪽을 위한 여러 입력·결과 타입을 허용한다. 하나의 고정 결과 타입을 추론하는 함수로 바꾸면 안 된다.

정확한 stack 변화는 결론의 `t_1* -> t_2*`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Instrtype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, UNREACHABLE, T-1-:SpectecTerminals ->- eps  T-2-:SpectecTerminals) = true
  if Instrtype-ok(C:SpectecTerminal, T-1-:SpectecTerminals ->- eps  T-2-:SpectecTerminals) .
```


### 55.3. `Instr_ok/drop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:25)

**SpecTec**


```spectec
rule Instr_ok/drop:
  C |- DROP : t -> eps
  -- Valtype_ok: C |- t : OK
```

**의미**

DROP는 올바른 값 타입 t 하나를 stack에서 제거한다.

정확한 stack 변화는 결론의 `t -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Valtype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, DROP, T:SpectecTerminal ->- eps  eps) = true
  if Valtype-ok(C:SpectecTerminal, T:SpectecTerminal) .
```


### 55.4. `Instr_ok/select-expl`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:29)

**SpecTec**


```spectec
rule Instr_ok/select-expl:
  C |- SELECT t : t t I32 -> t
  -- Valtype_ok: C |- t : OK
```

**의미**

명시된 타입 t의 두 값과 I32 조건을 받아 t 하나를 남긴다.

정확한 stack 변화는 결론의 `t t I32 -> t`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Valtype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, SELECT(seq(T:SpectecTerminal) ?), (T:SpectecTerminal (T:SpectecTerminal I32)) ->- eps  T:SpectecTerminal) = true
  if Valtype-ok(C:SpectecTerminal, T:SpectecTerminal) .
```


### 55.5. `Instr_ok/select-impl`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:33)

**SpecTec**


```spectec
rule Instr_ok/select-impl:
  C |- SELECT : t t I32 -> t
  -- Valtype_ok: C |- t : OK
  -- Valtype_sub: C |- t <: t'
  -- if t' = numtype \/ t' = vectype
```

**의미**

타입 표시가 없는 SELECT는 t 값 두 개와 I32 조건을 받는다. t가 숫자 또는 벡터 타입으로 사용될 수 있어야 한다. 비교에 쓰는 상위 타입 t'는 중간 값이다.

정확한 stack 변화는 결론의 `t t I32 -> t`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Valtype_ok`, `Valtype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 추가 입력을 받은 조건 검사식. 원래 호출에 대한 완성된 판정기는 아님.**


```maude
op Instr-ok-via-select-impl : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
ceq Instr-ok-via-select-impl(C:SpectecTerminal, T:SpectecTerminal, UPPER:SpectecTerminal) = true
  if Valtype-ok(C:SpectecTerminal, T:SpectecTerminal)
    /\ Valtype-sub(C:SpectecTerminal, T:SpectecTerminal, UPPER:SpectecTerminal)
    /\ _or_(typecheck(UPPER:SpectecTerminal, numtype), typecheck(UPPER:SpectecTerminal, vectype)) .
--- 이 검사는 SELECT(eps) : (T T I32) ->- eps T를 위한 것이다.
```


### 55.6. `Instr_ok/block`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:53)

**SpecTec**


```spectec
rule Instr_ok/block:
  C |- BLOCK bt instr* : t_1* -> t_2*
  -- Blocktype_ok: C |- bt : t_1* -> t_2*
  -- Instrs_ok: {LABELS (t_2*)} ++ C |- instr* : t_1* ->_(x*) t_2*
```

**의미**

block type의 입력·결과를 확인하고 결과 타입을 label 앞에 추가해 본문을 검사한다. 본문이 초기화하는 local 번호 리스트 x*는 바깥 결론에 없다.

정확한 stack 변화는 결론의 `t_1* -> t_2*`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Blocktype_ok`, `Instrs_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 추가 입력을 받은 조건 검사식. 원래 호출에 대한 완성된 판정기는 아님.**


```maude
op Instr-ok-via-block : SpectecTerminal SpectecTerminal SpectecTerminal SpectecTerminals ~> Bool .
ceq Instr-ok-via-block(C:SpectecTerminal, BLOCK(BT:SpectecTerminal, IS:InstrList), T1:SpectecTerminals ->- eps T2:SpectecTerminals, XS:SpectecTerminals) = true
  if Blocktype-ok(C:SpectecTerminal, BT:SpectecTerminal, T1:SpectecTerminals ->- eps T2:SpectecTerminals)
    /\ Instrs-ok(recordConcat(label-context(T2:SpectecTerminals), C:SpectecTerminal, context), IS:InstrList, T1:SpectecTerminals ->- XS:SpectecTerminals T2:SpectecTerminals) .
```


### 55.7. `Instr_ok/loop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:58)

**SpecTec**


```spectec
rule Instr_ok/loop:
  C |- LOOP bt instr* : t_1* -> t_2*
  -- Blocktype_ok: C |- bt : t_1* -> t_2*
  -- Instrs_ok: {LABELS (t_1*)} ++ C |- instr* : t_1* ->_(x*) t_2*
```

**의미**

loop type을 확인하고 입력 타입을 label 앞에 추가해 본문을 검사한다. loop label로 분기하면 입력 타입을 다시 받는다.

정확한 stack 변화는 결론의 `t_1* -> t_2*`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Blocktype_ok`, `Instrs_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 추가 입력을 받은 조건 검사식. 원래 호출에 대한 완성된 판정기는 아님.**


```maude
op Instr-ok-via-loop : SpectecTerminal SpectecTerminal SpectecTerminal SpectecTerminals ~> Bool .
ceq Instr-ok-via-loop(C:SpectecTerminal, LOOP(BT:SpectecTerminal, IS:InstrList), T1:SpectecTerminals ->- eps T2:SpectecTerminals, XS:SpectecTerminals) = true
  if Blocktype-ok(C:SpectecTerminal, BT:SpectecTerminal, T1:SpectecTerminals ->- eps T2:SpectecTerminals)
    /\ Instrs-ok(recordConcat(label-context(T1:SpectecTerminals), C:SpectecTerminal, context), IS:InstrList, T1:SpectecTerminals ->- XS:SpectecTerminals T2:SpectecTerminals) .
```


### 55.8. `Instr_ok/if`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:63)

**SpecTec**


```spectec
rule Instr_ok/if:
  C |- IF bt instr_1* ELSE instr_2* : t_1* I32 -> t_2*
  -- Blocktype_ok: C |- bt : t_1* -> t_2*
  -- Instrs_ok: {LABELS (t_2*)} ++ C |- instr_1* : t_1* ->_(x_1*) t_2*
  -- Instrs_ok: {LABELS (t_2*)} ++ C |- instr_2* : t_1* ->_(x_2*) t_2*
```

**의미**

I32 조건을 소비한다. 두 분기 본문을 같은 입력·결과 타입으로 각각 검사하며, 각 분기의 local 초기화 정보는 따로 확인한다.

정확한 stack 변화는 결론의 `t_1* I32 -> t_2*`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Blocktype_ok`, `Instrs_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 추가 입력을 받은 조건 검사식. 원래 호출에 대한 완성된 판정기는 아님.**


```maude
op Instr-ok-via-if : SpectecTerminal SpectecTerminal SpectecTerminal SpectecTerminals SpectecTerminals ~> Bool .
ceq Instr-ok-via-if(C:SpectecTerminal, IF BT:SpectecTerminal IS1:InstrList ELSE IS2:InstrList, (T1:SpectecTerminals I32) ->- eps T2:SpectecTerminals, X1:SpectecTerminals, X2:SpectecTerminals) = true
  if Blocktype-ok(C:SpectecTerminal, BT:SpectecTerminal, T1:SpectecTerminals ->- eps T2:SpectecTerminals)
    /\ Instrs-ok(recordConcat(label-context(T2:SpectecTerminals), C:SpectecTerminal, context), IS1:InstrList, T1:SpectecTerminals ->- X1:SpectecTerminals T2:SpectecTerminals)
    /\ Instrs-ok(recordConcat(label-context(T2:SpectecTerminals), C:SpectecTerminal, context), IS2:InstrList, T1:SpectecTerminals ->- X2:SpectecTerminals T2:SpectecTerminals) .
```


### 55.9. `Instr_ok/br`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:72)

**SpecTec**


```spectec
rule Instr_ok/br:
  C |- BR l : t_1* t* -> t_2*
  -- if C.LABELS[l] = t*
  -- Instrtype_ok: C |- t_1* -> t_2* : OK
```

**의미**

대상 label에 넘길 값 타입들과 나머지 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `t_1* t* -> t_2*`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Instrtype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, BR(L:Nat), (T-1-:SpectecTerminals T-:SpectecTerminals) ->- eps  T-2-:SpectecTerminals) = true
  if unseq((C:SpectecTerminal . 'LABELS) [ L:Nat ]) == T-:SpectecTerminals
    /\ Instrtype-ok(C:SpectecTerminal, T-1-:SpectecTerminals ->- eps  T-2-:SpectecTerminals) .
```


### 55.10. `Instr_ok/br_if`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:77)

**SpecTec**


```spectec
rule Instr_ok/br_if:
  C |- BR_IF l : t* I32 -> t*
  -- if C.LABELS[l] = t*
```

**의미**

I32 조건과 label이 요구하는 값들을 받고, 분기하지 않을 경우 그 값들을 stack에 남긴다.

정확한 stack 변화는 결론의 `t* I32 -> t*`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, BR-IF(L:Nat), (T-:SpectecTerminals I32) ->- eps  T-:SpectecTerminals) = true
  if unseq((C:SpectecTerminal . 'LABELS) [ L:Nat ]) == T-:SpectecTerminals .
```


### 55.11. `Instr_ok/br_table`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:81)

**SpecTec**


```spectec
rule Instr_ok/br_table:
  C |- BR_TABLE l* l' : t_1* t* I32 -> t_2*
  -- (Resulttype_sub: C |- t* <: C.LABELS[l])*
  -- Resulttype_sub: C |- t* <: C.LABELS[l']
  -- Instrtype_ok: C |- t_1* t* I32 -> t_2* : OK
```

**의미**

모든 대상 label에 동일한 값들을 넘길 수 있는지 확인하고 I32 대상 번호를 소비한다.

정확한 stack 변화는 결론의 `t_1* t* I32 -> t_2*`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Instrtype_ok`, `Resulttype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, BR-TABLE(L-:SpectecTerminals, L-2:Nat), (T-1-:SpectecTerminals (T-:SpectecTerminals I32)) ->- eps  T-2-:SpectecTerminals) = true
  if iterpr-17(C:SpectecTerminal, T-:SpectecTerminals, L-:SpectecTerminals)
    /\ Resulttype-sub(C:SpectecTerminal, T-:SpectecTerminals, unseq((C:SpectecTerminal . 'LABELS) [ L-2:Nat ]))
    /\ Instrtype-ok(C:SpectecTerminal, (T-1-:SpectecTerminals (T-:SpectecTerminals I32)) ->- eps  T-2-:SpectecTerminals) .
```


### 55.12. `Instr_ok/br_on_null`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:87)

**SpecTec**


```spectec
rule Instr_ok/br_on_null:
  C |- BR_ON_NULL l : t* (REF NULL ht) -> t* (REF ht)
  -- if C.LABELS[l] = t*
  -- Heaptype_ok: C |- ht : OK
```

**의미**

nullable 참조를 검사한다. 분기하지 않는 경로에는 null이 아닌 참조를 남긴다.

정확한 stack 변화는 결론의 `t* (REF NULL ht) -> t* (REF ht)`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Heaptype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, BR-ON-NULL(L:Nat), (T-:SpectecTerminals REF(NULL ?, HT:SpectecTerminal)) ->- eps  (T-:SpectecTerminals REF(eps, HT:SpectecTerminal))) = true
  if unseq((C:SpectecTerminal . 'LABELS) [ L:Nat ]) == T-:SpectecTerminals
    /\ Heaptype-ok(C:SpectecTerminal, HT:SpectecTerminal) .
```


### 55.13. `Instr_ok/br_on_non_null`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:92)

**SpecTec**


```spectec
rule Instr_ok/br_on_non_null:
  C |- BR_ON_NON_NULL l : t* (REF NULL ht) -> t*
  -- if C.LABELS[l] = t* (REF NULL? ht)
```

**의미**

nullable 참조가 null이 아닐 때 label에 넘길 수 있는 참조 타입인지 확인한다.

정확한 stack 변화는 결론의 `t* (REF NULL ht) -> t*`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, BR-ON-NON-NULL(L:Nat), (TS:SpectecTerminals REF(NULL ?, HT:SpectecTerminal)) ->- eps TS:SpectecTerminals) = true
  if unseq((C:SpectecTerminal . 'LABELS)[L:Nat]) == (TS:SpectecTerminals REF(eps, HT:SpectecTerminal)) .
ceq Instr-ok(C:SpectecTerminal, BR-ON-NON-NULL(L:Nat), (TS:SpectecTerminals REF(NULL ?, HT:SpectecTerminal)) ->- eps TS:SpectecTerminals) = true
  if unseq((C:SpectecTerminal . 'LABELS)[L:Nat]) == (TS:SpectecTerminals REF(NULL ?, HT:SpectecTerminal)) .
```


### 55.14. `Instr_ok/br_on_cast`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:96)

**SpecTec**


```spectec
rule Instr_ok/br_on_cast:
  C |- BR_ON_CAST l rt_1 rt_2 : t* rt_1 -> t* ($diffrt(rt_1, rt_2))
  -- if C.LABELS[l] = t* rt
  -- Reftype_ok: C |- rt_1 : OK
  -- Reftype_ok: C |- rt_2 : OK
  -- Reftype_sub: C |- rt_2 <: rt_1
  -- Reftype_sub: C |- rt_2 <: rt
```

**의미**

두 참조 타입이 올바르고 cast 결과를 label에 넘길 수 있는지 검사한다. 계속 진행하는 쪽에는 diffrt로 계산한 타입을 남긴다.

정확한 stack 변화는 결론의 `t* rt_1 -> t* ($diffrt(rt_1, rt_2))`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Reftype_ok`, `Reftype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, BR-ON-CAST(L:Nat, RT-1:SpectecTerminal, RT-2:SpectecTerminal), REL-INPUT3:SpectecTerminal) = true
  if CASE-PART1:SpectecTerminals ->- CASE-PART2:SpectecTerminals  CASE-PART3:SpectecTerminals := REL-INPUT3:SpectecTerminal
    /\ T-:SpectecTerminals RT-1:SpectecTerminal := CASE-PART1:SpectecTerminals
    /\ typecheck(RT-1:SpectecTerminal, reftype)
    /\ eps = CASE-PART2:SpectecTerminals
    /\ T-:SpectecTerminals diffrt(RT-1:SpectecTerminal, RT-2:SpectecTerminal) = CASE-PART3:SpectecTerminals
    /\ T-:SpectecTerminals RT:SpectecTerminal := unseq((C:SpectecTerminal . 'LABELS) [ L:Nat ])
    /\ typecheck(RT:SpectecTerminal, reftype)
    /\ Reftype-ok(C:SpectecTerminal, RT-1:SpectecTerminal)
    /\ Reftype-ok(C:SpectecTerminal, RT-2:SpectecTerminal)
    /\ Reftype-sub(C:SpectecTerminal, RT-2:SpectecTerminal, RT-1:SpectecTerminal)
    /\ Reftype-sub(C:SpectecTerminal, RT-2:SpectecTerminal, RT:SpectecTerminal) .
```


### 55.15. `Instr_ok/br_on_cast_fail`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:104)

**SpecTec**


```spectec
rule Instr_ok/br_on_cast_fail:
  C |- BR_ON_CAST_FAIL l rt_1 rt_2 : t* rt_1 -> t* rt_2
  -- if C.LABELS[l] = t* rt
  -- Reftype_ok: C |- rt_1 : OK
  -- Reftype_ok: C |- rt_2 : OK
  -- Reftype_sub: C |- rt_2 <: rt_1
  -- Reftype_sub: C |- $diffrt(rt_1, rt_2) <: rt
```

**의미**

cast에 실패한 쪽을 label에 넘길 수 있는지 확인하고 성공한 쪽에는 목표 타입을 남긴다.

정확한 stack 변화는 결론의 `t* rt_1 -> t* rt_2`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Reftype_ok`, `Reftype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, BR-ON-CAST-FAIL(L:Nat, RT-1:SpectecTerminal, RT-2:SpectecTerminal), (T-:SpectecTerminals RT-1:SpectecTerminal) ->- eps  (T-:SpectecTerminals RT-2:SpectecTerminal)) = true
  if typecheck(RT-1:SpectecTerminal, reftype)
    /\ typecheck(RT-2:SpectecTerminal, reftype)
    /\ T-:SpectecTerminals RT:SpectecTerminal := unseq((C:SpectecTerminal . 'LABELS) [ L:Nat ])
    /\ typecheck(RT:SpectecTerminal, reftype)
    /\ Reftype-ok(C:SpectecTerminal, RT-1:SpectecTerminal)
    /\ Reftype-ok(C:SpectecTerminal, RT-2:SpectecTerminal)
    /\ Reftype-sub(C:SpectecTerminal, RT-2:SpectecTerminal, RT-1:SpectecTerminal)
    /\ Reftype-sub(C:SpectecTerminal, diffrt(RT-1:SpectecTerminal, RT-2:SpectecTerminal), RT:SpectecTerminal) .
```


### 55.16. `Instr_ok/call`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:115)

**SpecTec**


```spectec
rule Instr_ok/call:
  C |- CALL x : t_1* -> t_2*
  -- Expand: C.FUNCS[x] ~~ FUNC t_1* -> t_2*
```

**의미**

문맥 FUNCS의 함수 타입을 펼쳐 입력 인자를 소비하고 결과를 남기는 타입으로 인정한다.

정확한 stack 변화는 결론의 `t_1* -> t_2*`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Expand`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, CALL(X4:Nat), T-1-:SpectecTerminals ->- eps  T-2-:SpectecTerminals) = true
  if FUNC T-1-:SpectecTerminals -> T-2-:SpectecTerminals = Expand((C:SpectecTerminal . 'FUNCS) [ X4:Nat ]) .
```


### 55.17. `Instr_ok/call_ref`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:119)

**SpecTec**


```spectec
rule Instr_ok/call_ref:
  C |- CALL_REF (_IDX x) : t_1* (REF NULL (_IDX x)) -> t_2*
  -- Expand: C.TYPES[x] ~~ FUNC t_1* -> t_2*
```

**의미**

문맥 TYPES에서 함수 타입을 펼친다. 입력 인자들과 nullable 함수 참조 하나를 소비한다.

정확한 stack 변화는 결론의 `t_1* (REF NULL (_IDX x)) -> t_2*`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Expand`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, CALL-REF(-IDX(X4:Nat)), (T-1-:SpectecTerminals REF(NULL ?, -IDX(X4:Nat))) ->- eps  T-2-:SpectecTerminals) = true
  if FUNC T-1-:SpectecTerminals -> T-2-:SpectecTerminals = Expand((C:SpectecTerminal . 'TYPES) [ X4:Nat ]) .
```


### 55.18. `Instr_ok/call_indirect`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:123)

**SpecTec**


```spectec
rule Instr_ok/call_indirect:
  C |- CALL_INDIRECT x (_IDX y) : t_1* at -> t_2*
  -- if C.TABLES[x] = at lim rt
  -- Reftype_sub: C |- rt <: (REF NULL FUNC)
  -- Expand: C.TYPES[y] ~~ FUNC t_1* -> t_2*
```

**의미**

table의 참조 타입이 함수 참조에 맞는지 확인하고, 함수 입력과 table 주소 값을 소비한다.

정확한 stack 변화는 결론의 `t_1* at -> t_2*`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Expand`, `Reftype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, CALL-INDIRECT(X4:Nat, -IDX(Y:Nat)), (T-1-:SpectecTerminals AT:SpectecTerminal) ->- eps  T-2-:SpectecTerminals) = true
  if typecheck(AT:SpectecTerminal, addrtype)
    /\ tuple(AT:SpectecTerminal (LIM:SpectecTerminal RT:SpectecTerminal)) := (C:SpectecTerminal . 'TABLES) [ X4:Nat ]
    /\ Reftype-sub(C:SpectecTerminal, RT:SpectecTerminal, REF(NULL ?, spectec-FUNC))
    /\ FUNC T-1-:SpectecTerminals -> T-2-:SpectecTerminals = Expand((C:SpectecTerminal . 'TYPES) [ Y:Nat ]) .
```


### 55.19. `Instr_ok/return`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:129)

**SpecTec**


```spectec
rule Instr_ok/return:
  C |- RETURN : t_1* t* -> t_2*
  -- if C.RETURN = (t*)
  -- Instrtype_ok: C |- t_1* -> t_2* : OK
```

**의미**

현재 함수의 RETURN 타입을 읽어 반환 값 타입을 확인한다.

정확한 stack 변화는 결론의 `t_1* t* -> t_2*`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Instrtype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, RETURN, (T-1-:SpectecTerminals T-:SpectecTerminals) ->- eps  T-2-:SpectecTerminals) = true
  if (C:SpectecTerminal . 'RETURN) == (seq(T-:SpectecTerminals) ?)
    /\ Instrtype-ok(C:SpectecTerminal, T-1-:SpectecTerminals ->- eps  T-2-:SpectecTerminals) .
```


### 55.20. `Instr_ok/return_call`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:135)

**SpecTec**


```spectec
rule Instr_ok/return_call:
  C |- RETURN_CALL x : t_3* t_1* -> t_4*
  -- Expand: C.FUNCS[x] ~~ FUNC t_1* -> t_2*
  -- if C.RETURN = (t'_2*)
  -- Resulttype_sub: C |- t_2* <: t'_2*
  -- Instrtype_ok: C |- t_3* -> t_4* : OK
```

**의미**

호출 대상의 입력·결과를 읽고 대상 결과가 현재 RETURN 타입으로 반환될 수 있는지 확인한다.

정확한 stack 변화는 결론의 `t_3* t_1* -> t_4*`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Expand`, `Instrtype_ok`, `Resulttype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, RETURN-CALL(X4:Nat), (T-3-:SpectecTerminals T-1-:SpectecTerminals) ->- eps  T-4-:SpectecTerminals) = true
  if FUNC T-1-:SpectecTerminals -> T-2-:SpectecTerminals := Expand((C:SpectecTerminal . 'FUNCS) [ X4:Nat ])
    /\ seq(T--2-:SpectecTerminals) ? := C:SpectecTerminal . 'RETURN
    /\ Resulttype-sub(C:SpectecTerminal, T-2-:SpectecTerminals, T--2-:SpectecTerminals)
    /\ Instrtype-ok(C:SpectecTerminal, T-3-:SpectecTerminals ->- eps  T-4-:SpectecTerminals) .
```


### 55.21. `Instr_ok/return_call_ref`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:143)

**SpecTec**


```spectec
rule Instr_ok/return_call_ref:
  C |- RETURN_CALL_REF (_IDX x) : t_3* t_1* (REF NULL (_IDX x)) -> t_4*
  -- Expand: C.TYPES[x] ~~ FUNC t_1* -> t_2*
  -- if C.RETURN = (t'_2*)
  -- Resulttype_sub: C |- t_2* <: t'_2*
  -- Instrtype_ok: C |- t_3* -> t_4* : OK
```

**의미**

참조로 tail call하는 대상의 입력·결과와 현재 RETURN 타입의 호환을 확인한다.

정확한 stack 변화는 결론의 `t_3* t_1* (REF NULL (_IDX x)) -> t_4*`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Expand`, `Instrtype_ok`, `Resulttype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, RETURN-CALL-REF(-IDX(X4:Nat)), (T-3-:SpectecTerminals (T-1-:SpectecTerminals REF(NULL ?, -IDX(X4:Nat)))) ->- eps  T-4-:SpectecTerminals) = true
  if FUNC T-1-:SpectecTerminals -> T-2-:SpectecTerminals := Expand((C:SpectecTerminal . 'TYPES) [ X4:Nat ])
    /\ seq(T--2-:SpectecTerminals) ? := C:SpectecTerminal . 'RETURN
    /\ Resulttype-sub(C:SpectecTerminal, T-2-:SpectecTerminals, T--2-:SpectecTerminals)
    /\ Instrtype-ok(C:SpectecTerminal, T-3-:SpectecTerminals ->- eps  T-4-:SpectecTerminals) .
```


### 55.22. `Instr_ok/return_call_indirect`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:151)

**SpecTec**


```spectec
rule Instr_ok/return_call_indirect:
  C |- RETURN_CALL_INDIRECT x (_IDX y) : t_3* t_1* at -> t_4*
  -- if C.TABLES[x] = at lim rt
  -- Reftype_sub: C |- rt <: (REF NULL FUNC)
  ----
  -- Expand: C.TYPES[y] ~~ FUNC t_1* -> t_2*
  -- if C.RETURN = (t'_2*)
  -- Resulttype_sub: C |- t_2* <: t'_2*
  -- Instrtype_ok: C |- t_3* -> t_4* : OK
```

**의미**

table을 통한 tail call의 대상 함수 타입과 현재 RETURN 타입의 호환을 확인한다.

정확한 stack 변화는 결론의 `t_3* t_1* at -> t_4*`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Expand`, `Instrtype_ok`, `Reftype_sub`, `Resulttype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, RETURN-CALL-INDIRECT(X4:Nat, -IDX(Y:Nat)), (T-3-:SpectecTerminals (T-1-:SpectecTerminals AT:SpectecTerminal)) ->- eps  T-4-:SpectecTerminals) = true
  if typecheck(AT:SpectecTerminal, addrtype)
    /\ tuple(AT:SpectecTerminal (LIM:SpectecTerminal RT:SpectecTerminal)) := (C:SpectecTerminal . 'TABLES) [ X4:Nat ]
    /\ Reftype-sub(C:SpectecTerminal, RT:SpectecTerminal, REF(NULL ?, spectec-FUNC))
    /\ FUNC T-1-:SpectecTerminals -> T-2-:SpectecTerminals := Expand((C:SpectecTerminal . 'TYPES) [ Y:Nat ])
    /\ seq(T--2-:SpectecTerminals) ? := C:SpectecTerminal . 'RETURN
    /\ Resulttype-sub(C:SpectecTerminal, T-2-:SpectecTerminals, T--2-:SpectecTerminals)
    /\ Instrtype-ok(C:SpectecTerminal, T-3-:SpectecTerminals ->- eps  T-4-:SpectecTerminals) .
```


### 55.23. `Instr_ok/throw`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:166)

**SpecTec**


```spectec
rule Instr_ok/throw:
  C |- THROW x : t_1* t* -> t_2*
  -- Expand: $as_deftype(C.TAGS[x]) ~~ FUNC t* -> eps
  -- Instrtype_ok: C |- t_1* -> t_2* : OK
```

**의미**

tag 함수 타입의 입력을 예외 payload 타입으로 읽는다. 이 값들을 소비하고 일반 경로로 돌아오지 않는 타입이다.

정확한 stack 변화는 결론의 `t_1* t* -> t_2*`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Expand`, `Instrtype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, THROW(X4:Nat), (T-1-:SpectecTerminals T-:SpectecTerminals) ->- eps  T-2-:SpectecTerminals) = true
  if FUNC T-:SpectecTerminals -> eps = Expand(as-deftype((C:SpectecTerminal . 'TAGS) [ X4:Nat ]))
    /\ Instrtype-ok(C:SpectecTerminal, T-1-:SpectecTerminals ->- eps  T-2-:SpectecTerminals) .
```


### 55.24. `Instr_ok/throw_ref`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:171)

**SpecTec**


```spectec
rule Instr_ok/throw_ref:
  C |- THROW_REF : t_1* (REF NULL EXN) -> t_2*
  -- Instrtype_ok: C |- t_1* -> t_2* : OK
```

**의미**

nullable 예외 참조 하나를 소비하는 명령어 타입이다. 실제 null 여부에 따른 trap은 실행 rule에서 정한다.

정확한 stack 변화는 결론의 `t_1* (REF NULL EXN) -> t_2*`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Instrtype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, THROW-REF, (T-1-:SpectecTerminals REF(NULL ?, EXN)) ->- eps  T-2-:SpectecTerminals) = true
  if Instrtype-ok(C:SpectecTerminal, T-1-:SpectecTerminals ->- eps  T-2-:SpectecTerminals) .
```


### 55.25. `Instr_ok/try_table`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:175)

**SpecTec**


```spectec
rule Instr_ok/try_table:
  C |- TRY_TABLE bt catch* instr* : t_1* -> t_2*
  -- Blocktype_ok: C |- bt : t_1* -> t_2*
  -- Instrs_ok: {LABELS (t_2*)} ++ C |- instr* : t_1* ->_(x*) t_2*
  -- (Catch_ok: C |- catch : OK)*
```

**의미**

block 본문의 타입과 local 초기화 정보를 확인하고 모든 catch 대상의 타입도 확인한다.

정확한 stack 변화는 결론의 `t_1* -> t_2*`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Blocktype_ok`, `Catch_ok`, `Instrs_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 추가 입력을 받은 조건 검사식. 원래 호출에 대한 완성된 판정기는 아님.**


```maude
op Instr-ok-via-try-table : SpectecTerminal SpectecTerminal SpectecTerminal SpectecTerminals ~> Bool .
ceq Instr-ok-via-try-table(C:SpectecTerminal, TRY-TABLE(BT:SpectecTerminal, CS:SpectecTerminals, IS:InstrList), T1:SpectecTerminals ->- eps T2:SpectecTerminals, XS:SpectecTerminals) = true
  if Blocktype-ok(C:SpectecTerminal, BT:SpectecTerminal, T1:SpectecTerminals ->- eps T2:SpectecTerminals)
    /\ Instrs-ok(recordConcat(label-context(T2:SpectecTerminals), C:SpectecTerminal, context), IS:InstrList, T1:SpectecTerminals ->- XS:SpectecTerminals T2:SpectecTerminals)
    /\ catches-ok(C:SpectecTerminal, CS:SpectecTerminals) .
```


### 55.26. `Instr_ok/ref.null`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:202)

**SpecTec**


```spectec
rule Instr_ok/ref.null:
  C |- REF.NULL ht : eps -> (REF NULL ht)
  -- Heaptype_ok: C |- ht : OK
```

**의미**

올바른 대상 타입 ht의 nullable 참조를 만든다.

정확한 stack 변화는 결론의 `eps -> (REF NULL ht)`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Heaptype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, REF.NULL(HT:SpectecTerminal), eps ->- eps  REF(NULL ?, HT:SpectecTerminal)) = true
  if Heaptype-ok(C:SpectecTerminal, HT:SpectecTerminal) .
```


### 55.27. `Instr_ok/ref.func`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:206)

**SpecTec**


```spectec
rule Instr_ok/ref.func:
  C |- REF.FUNC x : eps -> (REF dt)
  -- if C.FUNCS[x] = dt
  -- if x <- C.REFS
```

**의미**

함수 번호가 존재하고 C.REFS에 등록되어 있으면 그 함수 타입의 non-null 참조를 만든다.

정확한 stack 변화는 결론의 `eps -> (REF dt)`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, REF.FUNC(X4:Nat), eps ->- eps  REF(eps, DT:SpectecTerminal)) = true
  if typecheck(DT:SpectecTerminal, deftype)
    /\ ((C:SpectecTerminal . 'FUNCS) [ X4:Nat ]) == DT:SpectecTerminal
    /\ X4:Nat <- (C:SpectecTerminal . 'REFS) .
```


### 55.28. `Instr_ok/ref.i31`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:211)

**SpecTec**


```spectec
rule Instr_ok/ref.i31:
  C |- REF.I31 : I32 -> (REF I31)
```

**의미**

I32 값을 받아 i31 참조를 만든다.

정확한 stack 변화는 결론의 `I32 -> (REF I31)`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, REF.I31, I32 ->- eps  REF(eps, I31)) = true .
```


### 55.29. `Instr_ok/ref.is_null`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:214)

**SpecTec**


```spectec
rule Instr_ok/ref.is_null:
  C |- REF.IS_NULL : (REF NULL ht) -> I32
  -- Heaptype_ok: C |- ht : OK
```

**의미**

nullable 참조를 받아 I32 결과를 남기는 명령어 타입이다. 결과 0/1 자체를 여기서 계산하지 않는다.

정확한 stack 변화는 결론의 `(REF NULL ht) -> I32`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Heaptype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, REF.IS-NULL, REF(NULL ?, HT:SpectecTerminal) ->- eps  I32) = true
  if Heaptype-ok(C:SpectecTerminal, HT:SpectecTerminal) .
```


### 55.30. `Instr_ok/ref.as_non_null`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:218)

**SpecTec**


```spectec
rule Instr_ok/ref.as_non_null:
  C |- REF.AS_NON_NULL : (REF NULL ht) -> (REF ht)
  -- Heaptype_ok: C |- ht : OK
```

**의미**

nullable 참조를 같은 대상 종류의 non-null 참조로 바꾸는 명령어 타입이다.

정확한 stack 변화는 결론의 `(REF NULL ht) -> (REF ht)`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Heaptype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, REF.AS-NON-NULL, REF(NULL ?, HT:SpectecTerminal) ->- eps  REF(eps, HT:SpectecTerminal)) = true
  if Heaptype-ok(C:SpectecTerminal, HT:SpectecTerminal) .
```


### 55.31. `Instr_ok/ref.eq`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:222)

**SpecTec**


```spectec
rule Instr_ok/ref.eq:
  C |- REF.EQ : (REF NULL EQ) (REF NULL EQ) -> I32
```

**의미**

EQ 종류의 nullable 참조 두 개를 비교하여 I32 결과를 남긴다.

정확한 stack 변화는 결론의 `(REF NULL EQ) (REF NULL EQ) -> I32`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, REF.EQ, (REF(NULL ?, EQ) REF(NULL ?, EQ)) ->- eps  I32) = true .
```


### 55.32. `Instr_ok/ref.test`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:225)

**SpecTec**


```spectec
rule Instr_ok/ref.test:
  C |- REF.TEST rt : rt' -> I32
  -- Reftype_ok: C |- rt : OK
  -- Reftype_ok: C |- rt' : OK
  -- Reftype_sub: C |- rt <: rt'
```

**의미**

대상 참조 타입과 입력 타입을 확인한다. 실행 시 0인지 1인지는 실행 rule의 Ref_ok가 결정한다.

정확한 stack 변화는 결론의 `rt' -> I32`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Reftype_ok`, `Reftype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, REF.TEST(RT:SpectecTerminal), RT-:SpectecTerminal ->- eps  I32) = true
  if typecheck(RT-:SpectecTerminal, reftype)
    /\ Reftype-ok(C:SpectecTerminal, RT:SpectecTerminal)
    /\ Reftype-ok(C:SpectecTerminal, RT-:SpectecTerminal)
    /\ Reftype-sub(C:SpectecTerminal, RT:SpectecTerminal, RT-:SpectecTerminal) .
```


### 55.33. `Instr_ok/ref.cast`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:231)

**SpecTec**


```spectec
rule Instr_ok/ref.cast:
  C |- REF.CAST rt : rt' -> rt
  -- Reftype_ok: C |- rt : OK
  -- Reftype_ok: C |- rt' : OK
  -- Reftype_sub: C |- rt <: rt'
```

**의미**

cast 목표 타입이 입력 참조 타입의 subtype인지 확인한다. 실행 중 성공·trap은 실행 rule에서 결정한다.

정확한 stack 변화는 결론의 `rt' -> rt`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Reftype_ok`, `Reftype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, REF.CAST(RT:SpectecTerminal), RT-:SpectecTerminal ->- eps  RT:SpectecTerminal) = true
  if typecheck(RT-:SpectecTerminal, reftype)
    /\ typecheck(RT:SpectecTerminal, reftype)
    /\ Reftype-ok(C:SpectecTerminal, RT:SpectecTerminal)
    /\ Reftype-ok(C:SpectecTerminal, RT-:SpectecTerminal)
    /\ Reftype-sub(C:SpectecTerminal, RT:SpectecTerminal, RT-:SpectecTerminal) .
```


### 55.34. `Instr_ok/i31.get`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:240)

**SpecTec**


```spectec
rule Instr_ok/i31.get:
  C |- I31.GET sx : (REF NULL I31) -> I32
```

**의미**

i31 nullable 참조를 받아 I32를 남긴다. null 여부의 실행 효과는 별도 실행 rule에 있다.

정확한 stack 변화는 결론의 `(REF NULL I31) -> I32`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, I31.GET(SX:SpectecTerminal), REF(NULL ?, I31) ->- eps  I32) = true .
```


### 55.35. `Instr_ok/struct.new`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:246)

**SpecTec**


```spectec
rule Instr_ok/struct.new:
  C |- STRUCT.NEW x : $unpack(zt)* -> (REF (_IDX x))
  -- Expand: C.TYPES[x] ~~ STRUCT (mut? zt)*
```

**의미**

정의 타입을 STRUCT로 펼치고 각 필드 저장 타입을 unpack한 값들을 입력 stack으로 삼는다. 결과는 새 struct의 non-null 참조이다.

정확한 stack 변화는 결론의 `$unpack(zt)* -> (REF (_IDX x))`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Expand`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, STRUCT.NEW(X:Nat), IT:SpectecTerminal) = true
  if spectec-STRUCT(FTS:SpectecTerminals) := Expand((C:SpectecTerminal . 'TYPES)[X:Nat])
    /\ IT:SpectecTerminal == (unpack-fields(FTS:SpectecTerminals) ->- eps REF(eps, -IDX(X:Nat))) .
```


### 55.36. `Instr_ok/struct.new_default`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:250)

**SpecTec**


```spectec
rule Instr_ok/struct.new_default:
  C |- STRUCT.NEW_DEFAULT x : eps -> (REF (_IDX x))
  -- Expand: C.TYPES[x] ~~ STRUCT (mut? zt)*
  -- (Defaultable: |- $unpack(zt) DEFAULTABLE)*
```

**의미**

STRUCT의 각 필드에 기본값을 만들 수 있어야 한다. 외부 입력 값 없이 새 struct 참조를 만든다.

정확한 stack 변화는 결론의 `eps -> (REF (_IDX x))`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Defaultable`, `Expand`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, STRUCT.NEW-DEFAULT(X4:Nat), eps ->- eps  REF(eps, -IDX(X4:Nat))) = true
  if REL-OUTPUT1:SpectecTerminal := Expand((C:SpectecTerminal . 'TYPES) [ X4:Nat ])
    /\ spectec-STRUCT(CASE-PART1:SpectecTerminals) := REL-OUTPUT1:SpectecTerminal
    /\ tuple(seq(MUT--:SpectecTerminals) seq(ZT-:SpectecTerminals)) := project-map-exp-618(CASE-PART1:SpectecTerminals)
    /\ iterpr-19(ZT-:SpectecTerminals) .
```


### 55.37. `Instr_ok/struct.get`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:258)

**SpecTec**


```spectec
rule Instr_ok/struct.get:
  C |- STRUCT.GET sx? x i : (REF NULL (_IDX x)) -> $unpack(zt)
  -- Expand: C.TYPES[x] ~~ STRUCT ft*
  -- if ft*[i] = mut? zt
  -- if sx? =/= eps <=> $is_packtype(zt)
```

**의미**

field 번호의 저장 타입을 읽고 unpack한 값 타입을 결과로 정한다. packed 필드일 때만 부호 확장 표시가 있어야 한다.

정확한 stack 변화는 결론의 `(REF NULL (_IDX x)) -> $unpack(zt)`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Expand`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, STRUCT.GET(SXS:SpectecTerminals, X:Nat, I:Nat), IT:SpectecTerminal) = true
  if spectec-STRUCT(FTS:SpectecTerminals) := Expand((C:SpectecTerminal . 'TYPES)[X:Nat])
    /\ tuple(seq(MUTS:SpectecTerminals) ZT:SpectecTerminal) := FTS:SpectecTerminals[I:Nat]
    /\ (SXS:SpectecTerminals =/= eps) == is-packtype(ZT:SpectecTerminal)
    /\ IT:SpectecTerminal == (REF(NULL ?, -IDX(X:Nat)) ->- eps unpack(ZT:SpectecTerminal)) .
```


### 55.38. `Instr_ok/struct.set`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:264)

**SpecTec**


```spectec
rule Instr_ok/struct.set:
  C |- STRUCT.SET x i : (REF NULL (_IDX x)) $unpack(zt) -> eps
  -- Expand: C.TYPES[x] ~~ STRUCT ft*
  -- if ft*[i] = MUT zt
```

**의미**

선택한 필드가 MUT이어야 한다. struct 참조와 unpack한 새 필드 값을 소비한다.

정확한 stack 변화는 결론의 `(REF NULL (_IDX x)) $unpack(zt) -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Expand`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, STRUCT.SET(X:Nat, I:Nat), IT:SpectecTerminal) = true
  if spectec-STRUCT(FTS:SpectecTerminals) := Expand((C:SpectecTerminal . 'TYPES)[X:Nat])
    /\ tuple(seq(MUT ?) ZT:SpectecTerminal) := FTS:SpectecTerminals[I:Nat]
    /\ IT:SpectecTerminal == ((REF(NULL ?, -IDX(X:Nat)) unpack(ZT:SpectecTerminal)) ->- eps eps) .
```


### 55.39. `Instr_ok/array.new`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:272)

**SpecTec**


```spectec
rule Instr_ok/array.new:
  C |- ARRAY.NEW x : $unpack(zt) I32 -> (REF (_IDX x))
  -- Expand: C.TYPES[x] ~~ ARRAY (mut? zt)
```

**의미**

ARRAY 원소 타입을 읽어 초기 값 하나와 I32 길이를 소비하고 새 참조를 만든다.

정확한 stack 변화는 결론의 `$unpack(zt) I32 -> (REF (_IDX x))`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Expand`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, ARRAY.NEW(X:Nat), IT:SpectecTerminal) = true
  if spectec-ARRAY(tuple(seq(MUTS:SpectecTerminals) ZT:SpectecTerminal)) := Expand((C:SpectecTerminal . 'TYPES)[X:Nat])
    /\ IT:SpectecTerminal == ((unpack(ZT:SpectecTerminal) I32) ->- eps REF(eps, -IDX(X:Nat))) .
```


### 55.40. `Instr_ok/array.new_default`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:276)

**SpecTec**


```spectec
rule Instr_ok/array.new_default:
  C |- ARRAY.NEW_DEFAULT x : I32 -> (REF (_IDX x))
  -- Expand: C.TYPES[x] ~~ ARRAY (mut? zt)
  -- Defaultable: |- $unpack(zt) DEFAULTABLE
```

**의미**

ARRAY 원소의 기본값이 있어야 한다. 길이만 소비해 새 참조를 만든다.

정확한 stack 변화는 결론의 `I32 -> (REF (_IDX x))`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Defaultable`, `Expand`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, ARRAY.NEW-DEFAULT(X4:Nat), I32 ->- eps  REF(eps, -IDX(X4:Nat))) = true
  if spectec-ARRAY(tuple(seq(MUT-:SpectecTerminals) ZT:SpectecTerminal)) := Expand((C:SpectecTerminal . 'TYPES) [ X4:Nat ])
    /\ len(MUT-:SpectecTerminals) <= 1
    /\ Defaultable(unpack(ZT:SpectecTerminal)) .
```


### 55.41. `Instr_ok/array.new_fixed`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:281)

**SpecTec**


```spectec
rule Instr_ok/array.new_fixed:
  C |- ARRAY.NEW_FIXED x n : $unpack(zt)^n -> (REF (_IDX x))
  -- Expand: C.TYPES[x] ~~ ARRAY (mut? zt)
```

**의미**

ARRAY 원소 타입을 unpack한 값을 n개 소비하고 새 참조를 만든다.

정확한 stack 변화는 결론의 `$unpack(zt)^n -> (REF (_IDX x))`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Expand`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, ARRAY.NEW-FIXED(X:Nat, N:Nat), IT:SpectecTerminal) = true
  if spectec-ARRAY(tuple(seq(MUTS:SpectecTerminals) ZT:SpectecTerminal)) := Expand((C:SpectecTerminal . 'TYPES)[X:Nat])
    /\ IT:SpectecTerminal == (repeatSeq(N:Nat, unpack(ZT:SpectecTerminal)) ->- eps REF(eps, -IDX(X:Nat))) .
```


### 55.42. `Instr_ok/array.new_elem`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:285)

**SpecTec**


```spectec
rule Instr_ok/array.new_elem:
  C |- ARRAY.NEW_ELEM x y : I32 I32 -> (REF (_IDX x))
  -- Expand: C.TYPES[x] ~~ ARRAY (mut? rt)
  -- Reftype_sub: C |- C.ELEMS[y] <: rt
```

**의미**

element segment의 타입이 array 원소 참조 타입으로 사용될 수 있는지 확인한다.

정확한 stack 변화는 결론의 `I32 I32 -> (REF (_IDX x))`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Expand`, `Reftype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, ARRAY.NEW-ELEM(X4:Nat, Y:Nat), (I32 I32) ->- eps  REF(eps, -IDX(X4:Nat))) = true
  if spectec-ARRAY(tuple(seq(MUT-:SpectecTerminals) RT:SpectecTerminal)) := Expand((C:SpectecTerminal . 'TYPES) [ X4:Nat ])
    /\ len(MUT-:SpectecTerminals) <= 1
    /\ typecheck(RT:SpectecTerminal, reftype)
    /\ Reftype-sub(C:SpectecTerminal, (C:SpectecTerminal . 'ELEMS) [ Y:Nat ], RT:SpectecTerminal) .
```


### 55.43. `Instr_ok/array.new_data`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:290)

**SpecTec**


```spectec
rule Instr_ok/array.new_data:
  C |- ARRAY.NEW_DATA x y : I32 I32 -> (REF (_IDX x))
  -- Expand: C.TYPES[x] ~~ ARRAY (mut? zt)
  -- if $unpack(zt) = numtype \/ $unpack(zt) = vectype
  -- if C.DATAS[y] = OK
```

**의미**

array 저장 타입을 unpack하면 숫자 또는 벡터 타입이어야 한다. data 번호도 존재해야 한다.

정확한 stack 변화는 결론의 `I32 I32 -> (REF (_IDX x))`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Expand`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, ARRAY.NEW-DATA(X:Nat, Y:Nat), IT:SpectecTerminal) = true
  if spectec-ARRAY(tuple(seq(MUTS:SpectecTerminals) ZT:SpectecTerminal)) := Expand((C:SpectecTerminal . 'TYPES)[X:Nat])
    /\ _or_(typecheck(unpack(ZT:SpectecTerminal), numtype), typecheck(unpack(ZT:SpectecTerminal), vectype))
    /\ OK := (C:SpectecTerminal . 'DATAS)[Y:Nat]
    /\ IT:SpectecTerminal == ((I32 I32) ->- eps REF(eps, -IDX(X:Nat))) .
```


### 55.44. `Instr_ok/array.get`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:296)

**SpecTec**


```spectec
rule Instr_ok/array.get:
  C |- ARRAY.GET sx? x : (REF NULL (_IDX x)) I32 -> $unpack(zt)
  -- Expand: C.TYPES[x] ~~ ARRAY (mut? zt)
  -- if sx? =/= eps <=> $is_packtype(zt)
```

**의미**

array 원소 저장 타입을 unpack한 값을 반환한다. packed 타입일 때만 확장 표시를 허용한다.

정확한 stack 변화는 결론의 `(REF NULL (_IDX x)) I32 -> $unpack(zt)`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Expand`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, ARRAY.GET(SXS:SpectecTerminals, X:Nat), IT:SpectecTerminal) = true
  if spectec-ARRAY(tuple(seq(MUTS:SpectecTerminals) ZT:SpectecTerminal)) := Expand((C:SpectecTerminal . 'TYPES)[X:Nat])
    /\ (SXS:SpectecTerminals =/= eps) == is-packtype(ZT:SpectecTerminal)
    /\ IT:SpectecTerminal == ((REF(NULL ?, -IDX(X:Nat)) I32) ->- eps unpack(ZT:SpectecTerminal)) .
```


### 55.45. `Instr_ok/array.set`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:301)

**SpecTec**


```spectec
rule Instr_ok/array.set:
  C |- ARRAY.SET x : (REF NULL (_IDX x)) I32 $unpack(zt) -> eps
  -- Expand: C.TYPES[x] ~~ ARRAY (MUT zt)
```

**의미**

array 원소가 MUT이어야 하며 참조·번호·새 원소 값을 소비한다.

정확한 stack 변화는 결론의 `(REF NULL (_IDX x)) I32 $unpack(zt) -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Expand`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, ARRAY.SET(X:Nat), IT:SpectecTerminal) = true
  if spectec-ARRAY(tuple(seq(MUT ?) ZT:SpectecTerminal)) := Expand((C:SpectecTerminal . 'TYPES)[X:Nat])
    /\ IT:SpectecTerminal == ((REF(NULL ?, -IDX(X:Nat)) I32 unpack(ZT:SpectecTerminal)) ->- eps eps) .
```


### 55.46. `Instr_ok/array.len`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:305)

**SpecTec**


```spectec
rule Instr_ok/array.len:
  C |- ARRAY.LEN : (REF NULL ARRAY) -> I32
```

**의미**

array 참조를 받아 I32 길이를 남긴다.

정확한 stack 변화는 결론의 `(REF NULL ARRAY) -> I32`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, ARRAY.LEN, REF(NULL ?, ARRAY) ->- eps  I32) = true .
```


### 55.47. `Instr_ok/array.fill`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:308)

**SpecTec**


```spectec
rule Instr_ok/array.fill:
  C |- ARRAY.FILL x : (REF NULL (_IDX x)) I32 $unpack(zt) I32 -> eps
  -- Expand: C.TYPES[x] ~~ ARRAY (MUT zt)
```

**의미**

수정 가능한 array의 원소 타입에 맞는 채울 값과 범위를 확인한다.

정확한 stack 변화는 결론의 `(REF NULL (_IDX x)) I32 $unpack(zt) I32 -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Expand`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, ARRAY.FILL(X:Nat), IT:SpectecTerminal) = true
  if spectec-ARRAY(tuple(seq(MUT ?) ZT:SpectecTerminal)) := Expand((C:SpectecTerminal . 'TYPES)[X:Nat])
    /\ IT:SpectecTerminal == ((REF(NULL ?, -IDX(X:Nat)) I32 unpack(ZT:SpectecTerminal) I32) ->- eps eps) .
```


### 55.48. `Instr_ok/array.copy`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:312)

**SpecTec**


```spectec
rule Instr_ok/array.copy:
  C |- ARRAY.COPY x_1 x_2 : (REF NULL (_IDX x_1)) I32 (REF NULL (_IDX x_2)) I32 I32 -> eps
  -- Expand: C.TYPES[x_1] ~~ ARRAY (MUT zt_1)
  -- Expand: C.TYPES[x_2] ~~ ARRAY (mut? zt_2)
  -- Storagetype_sub: C |- zt_2 <: zt_1
```

**의미**

두 array의 원소 타입을 읽어 source 원소를 target 원소로 저장할 수 있는지 확인한다.

정확한 stack 변화는 결론의 `(REF NULL (_IDX x_1)) I32 (REF NULL (_IDX x_2)) I32 I32 -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Expand`, `Storagetype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, ARRAY.COPY(X-1:Nat, X-23:Nat), (REF(NULL ?, -IDX(X-1:Nat)) (I32 (REF(NULL ?, -IDX(X-23:Nat)) (I32 I32)))) ->- eps  eps) = true
  if spectec-ARRAY(tuple(seq(MUT ?) ZT-1:SpectecTerminal)) := Expand((C:SpectecTerminal . 'TYPES) [ X-1:Nat ])
    /\ spectec-ARRAY(tuple(seq(MUT-:SpectecTerminals) ZT-2:SpectecTerminal)) := Expand((C:SpectecTerminal . 'TYPES) [ X-23:Nat ])
    /\ len(MUT-:SpectecTerminals) <= 1
    /\ Storagetype-sub(C:SpectecTerminal, ZT-2:SpectecTerminal, ZT-1:SpectecTerminal) .
```


### 55.49. `Instr_ok/array.init_elem`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:318)

**SpecTec**


```spectec
rule Instr_ok/array.init_elem:
  C |- ARRAY.INIT_ELEM x y : (REF NULL (_IDX x)) I32 I32 I32 -> eps
  -- Expand: C.TYPES[x] ~~ ARRAY (MUT zt)
  -- Storagetype_sub: C |- C.ELEMS[y] <: zt
```

**의미**

element segment 참조 타입이 수정 가능한 array 원소 타입에 맞는지 확인한다.

정확한 stack 변화는 결론의 `(REF NULL (_IDX x)) I32 I32 I32 -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Expand`, `Storagetype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, ARRAY.INIT-ELEM(X4:Nat, Y:Nat), (REF(NULL ?, -IDX(X4:Nat)) (I32 (I32 I32))) ->- eps  eps) = true
  if spectec-ARRAY(tuple(seq(MUT ?) ZT:SpectecTerminal)) := Expand((C:SpectecTerminal . 'TYPES) [ X4:Nat ])
    /\ Storagetype-sub(C:SpectecTerminal, (C:SpectecTerminal . 'ELEMS) [ Y:Nat ], ZT:SpectecTerminal) .
```


### 55.50. `Instr_ok/array.init_data`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:323)

**SpecTec**


```spectec
rule Instr_ok/array.init_data:
  C |- ARRAY.INIT_DATA x y : (REF NULL (_IDX x)) I32 I32 I32 -> eps
  -- Expand: C.TYPES[x] ~~ ARRAY (MUT zt)
  -- if $unpack(zt) = numtype \/ $unpack(zt) = vectype
  -- if C.DATAS[y] = OK
```

**의미**

수정 가능한 array의 원소가 숫자 또는 벡터 값이며 data 번호가 존재해야 한다.

정확한 stack 변화는 결론의 `(REF NULL (_IDX x)) I32 I32 I32 -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Expand`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, ARRAY.INIT-DATA(X:Nat, Y:Nat), IT:SpectecTerminal) = true
  if spectec-ARRAY(tuple(seq(MUT ?) ZT:SpectecTerminal)) := Expand((C:SpectecTerminal . 'TYPES)[X:Nat])
    /\ _or_(typecheck(unpack(ZT:SpectecTerminal), numtype), typecheck(unpack(ZT:SpectecTerminal), vectype))
    /\ OK := (C:SpectecTerminal . 'DATAS)[Y:Nat]
    /\ IT:SpectecTerminal == ((REF(NULL ?, -IDX(X:Nat)) I32 I32 I32) ->- eps eps) .
```


### 55.51. `Instr_ok/extern.convert_any`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:332)

**SpecTec**


```spectec
rule Instr_ok/extern.convert_any:
  C |- EXTERN.CONVERT_ANY : (REF null_1? ANY) -> (REF null_2? EXTERN)
  -- if null_1? = null_2?
```

**의미**

ANY 참조를 외부 참조로 바꾸는 명령어의 입력·결과 타입이다.

정확한 stack 변화는 결론의 `(REF null_1? ANY) -> (REF null_2? EXTERN)`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, EXTERN.CONVERT-ANY, REF(NULL-1-:SpectecTerminals, ANY) ->- eps  REF(NULL-2-:SpectecTerminals, EXTERN)) = true
  if len(NULL-1-:SpectecTerminals) <= 1
    /\ len(NULL-2-:SpectecTerminals) <= 1
    /\ NULL-1-:SpectecTerminals == NULL-2-:SpectecTerminals .
```


### 55.52. `Instr_ok/any.convert_extern`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:336)

**SpecTec**


```spectec
rule Instr_ok/any.convert_extern:
  C |- ANY.CONVERT_EXTERN : (REF null_1? EXTERN) -> (REF null_2? ANY)
  -- if null_1? = null_2?
```

**의미**

외부 참조를 ANY 참조로 바꾸는 명령어의 입력·결과 타입이다.

정확한 stack 변화는 결론의 `(REF null_1? EXTERN) -> (REF null_2? ANY)`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, ANY.CONVERT-EXTERN, REF(NULL-1-:SpectecTerminals, EXTERN) ->- eps  REF(NULL-2-:SpectecTerminals, ANY)) = true
  if len(NULL-1-:SpectecTerminals) <= 1
    /\ len(NULL-2-:SpectecTerminals) <= 1
    /\ NULL-1-:SpectecTerminals == NULL-2-:SpectecTerminals .
```


### 55.53. `Instr_ok/local.get`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:343)

**SpecTec**


```spectec
rule Instr_ok/local.get:
  C |- LOCAL.GET x : eps -> t
  -- if C.LOCALS[x] = SET t
```

**의미**

local이 SET 상태인지 확인하고 그 값 타입을 stack에 남긴다.

정확한 stack 변화는 결론의 `eps -> t`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, LOCAL.GET(X4:Nat), eps ->- eps  T:SpectecTerminal) = true
  if ((C:SpectecTerminal . 'LOCALS) [ X4:Nat ]) == tuple(SET T:SpectecTerminal) .
```


### 55.54. `Instr_ok/local.set`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:347)

**SpecTec**


```spectec
rule Instr_ok/local.set:
  C |- LOCAL.SET x : t ->_(x) eps
  -- if C.LOCALS[x] = init t
```

**의미**

local의 값 타입에 맞는 값을 소비하고 해당 local의 초기화 효과를 표시한다.

정확한 stack 변화는 결론의 `t ->_(x) eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, LOCAL.SET(X4:Nat), T:SpectecTerminal ->- X4:Nat  eps) = true
  if tuple(INIT:SpectecTerminal T:SpectecTerminal) := (C:SpectecTerminal . 'LOCALS) [ X4:Nat ] .
```


### 55.55. `Instr_ok/local.tee`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:351)

**SpecTec**


```spectec
rule Instr_ok/local.tee:
  C |- LOCAL.TEE x : t ->_(x) t
  -- if C.LOCALS[x] = init t
```

**의미**

local에 저장하되 같은 값 타입을 stack에도 남긴다.

정확한 stack 변화는 결론의 `t ->_(x) t`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, LOCAL.TEE(X4:Nat), T:SpectecTerminal ->- X4:Nat  T:SpectecTerminal) = true
  if tuple(INIT:SpectecTerminal T:SpectecTerminal) := (C:SpectecTerminal . 'LOCALS) [ X4:Nat ] .
```


### 55.56. `Instr_ok/global.get`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:358)

**SpecTec**


```spectec
rule Instr_ok/global.get:
  C |- GLOBAL.GET x : eps -> t
  -- if C.GLOBALS[x] = mut? t
```

**의미**

global 타입에서 값 타입을 읽어 stack에 남긴다.

정확한 stack 변화는 결론의 `eps -> t`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, GLOBAL.GET(X4:Nat), eps ->- eps  T:SpectecTerminal) = true
  if tuple(seq(MUT-:SpectecTerminals) T:SpectecTerminal) := (C:SpectecTerminal . 'GLOBALS) [ X4:Nat ]
    /\ len(MUT-:SpectecTerminals) <= 1 .
```


### 55.57. `Instr_ok/global.set`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:362)

**SpecTec**


```spectec
rule Instr_ok/global.set:
  C |- GLOBAL.SET x : t -> eps
  -- if C.GLOBALS[x] = MUT t
```

**의미**

global이 MUT이어야 하며 해당 값 타입 하나를 소비한다.

정확한 stack 변화는 결론의 `t -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, GLOBAL.SET(X4:Nat), T:SpectecTerminal ->- eps  eps) = true
  if ((C:SpectecTerminal . 'GLOBALS) [ X4:Nat ]) == tuple(seq(MUT ?) T:SpectecTerminal) .
```


### 55.58. `Instr_ok/table.get`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:369)

**SpecTec**


```spectec
rule Instr_ok/table.get:
  C |- TABLE.GET x : at -> rt
  -- if C.TABLES[x] = at lim rt
```

**의미**

table 주소 타입과 원소 참조 타입을 문맥에서 읽어 명령어의 번호·값·결과 타입을 확인한다.

정확한 stack 변화는 결론의 `at -> rt`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, TABLE.GET(X4:Nat), AT:SpectecTerminal ->- eps  RT:SpectecTerminal) = true
  if typecheck(AT:SpectecTerminal, addrtype)
    /\ typecheck(RT:SpectecTerminal, reftype)
    /\ tuple(AT:SpectecTerminal (LIM:SpectecTerminal RT:SpectecTerminal)) := (C:SpectecTerminal . 'TABLES) [ X4:Nat ] .
```


### 55.59. `Instr_ok/table.set`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:373)

**SpecTec**


```spectec
rule Instr_ok/table.set:
  C |- TABLE.SET x : at rt -> eps
  -- if C.TABLES[x] = at lim rt
```

**의미**

table 주소 타입과 원소 참조 타입을 문맥에서 읽어 명령어의 번호·값·결과 타입을 확인한다.

정확한 stack 변화는 결론의 `at rt -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, TABLE.SET(X4:Nat), (AT:SpectecTerminal RT:SpectecTerminal) ->- eps  eps) = true
  if typecheck(AT:SpectecTerminal, addrtype)
    /\ typecheck(RT:SpectecTerminal, reftype)
    /\ tuple(AT:SpectecTerminal (LIM:SpectecTerminal RT:SpectecTerminal)) := (C:SpectecTerminal . 'TABLES) [ X4:Nat ] .
```


### 55.60. `Instr_ok/table.size`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:377)

**SpecTec**


```spectec
rule Instr_ok/table.size:
  C |- TABLE.SIZE x : eps -> at
  -- if C.TABLES[x] = at lim rt
```

**의미**

table 주소 타입과 원소 참조 타입을 문맥에서 읽어 명령어의 번호·값·결과 타입을 확인한다.

정확한 stack 변화는 결론의 `eps -> at`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, TABLE.SIZE(X4:Nat), eps ->- eps  AT:SpectecTerminal) = true
  if typecheck(AT:SpectecTerminal, addrtype)
    /\ tuple(AT:SpectecTerminal (LIM:SpectecTerminal RT:SpectecTerminal)) := (C:SpectecTerminal . 'TABLES) [ X4:Nat ] .
```


### 55.61. `Instr_ok/table.grow`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:381)

**SpecTec**


```spectec
rule Instr_ok/table.grow:
  C |- TABLE.GROW x : rt at -> at
  -- if C.TABLES[x] = at lim rt
```

**의미**

table 주소 타입과 원소 참조 타입을 문맥에서 읽어 명령어의 번호·값·결과 타입을 확인한다.

정확한 stack 변화는 결론의 `rt at -> at`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, TABLE.GROW(X4:Nat), (RT:SpectecTerminal AT:SpectecTerminal) ->- eps  AT:SpectecTerminal) = true
  if typecheck(RT:SpectecTerminal, reftype)
    /\ typecheck(AT:SpectecTerminal, addrtype)
    /\ typecheck(AT:SpectecTerminal, addrtype)
    /\ tuple(AT:SpectecTerminal (LIM:SpectecTerminal RT:SpectecTerminal)) := (C:SpectecTerminal . 'TABLES) [ X4:Nat ] .
```


### 55.62. `Instr_ok/table.fill`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:385)

**SpecTec**


```spectec
rule Instr_ok/table.fill:
  C |- TABLE.FILL x : at rt at -> eps
  -- if C.TABLES[x] = at lim rt
```

**의미**

table 주소 타입과 원소 참조 타입을 문맥에서 읽어 명령어의 번호·값·결과 타입을 확인한다.

정확한 stack 변화는 결론의 `at rt at -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, TABLE.FILL(X4:Nat), (AT:SpectecTerminal (RT:SpectecTerminal AT:SpectecTerminal)) ->- eps  eps) = true
  if typecheck(AT:SpectecTerminal, addrtype)
    /\ typecheck(RT:SpectecTerminal, reftype)
    /\ typecheck(AT:SpectecTerminal, addrtype)
    /\ tuple(AT:SpectecTerminal (LIM:SpectecTerminal RT:SpectecTerminal)) := (C:SpectecTerminal . 'TABLES) [ X4:Nat ] .
```


### 55.63. `Instr_ok/table.copy`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:389)

**SpecTec**


```spectec
rule Instr_ok/table.copy:
  C |- TABLE.COPY x_1 x_2 : at_1 at_2 $minat(at_1, at_2) -> eps
  -- if C.TABLES[x_1] = at_1 lim_1 rt_1
  -- if C.TABLES[x_2] = at_2 lim_2 rt_2
  -- Reftype_sub: C |- rt_2 <: rt_1
```

**의미**

table 주소 타입과 원소 참조 타입을 문맥에서 읽어 명령어의 번호·값·결과 타입을 확인한다.

정확한 stack 변화는 결론의 `at_1 at_2 $minat(at_1, at_2) -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Reftype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, TABLE.COPY(X-1:Nat, X-23:Nat), (AT-1:SpectecTerminal (AT-2:SpectecTerminal INPUT-FIELD:SpectecTerminal)) ->- eps  eps) = true
  if typecheck(AT-1:SpectecTerminal, addrtype)
    /\ typecheck(AT-2:SpectecTerminal, addrtype)
    /\ typecheck(INPUT-FIELD:SpectecTerminal, addrtype)
    /\ minat(AT-1:SpectecTerminal, AT-2:SpectecTerminal) = INPUT-FIELD:SpectecTerminal
    /\ tuple(AT-1:SpectecTerminal (LIM-1:SpectecTerminal RT-1:SpectecTerminal)) := (C:SpectecTerminal . 'TABLES) [ X-1:Nat ]
    /\ tuple(AT-2:SpectecTerminal (LIM-2:SpectecTerminal RT-2:SpectecTerminal)) := (C:SpectecTerminal . 'TABLES) [ X-23:Nat ]
    /\ Reftype-sub(C:SpectecTerminal, RT-2:SpectecTerminal, RT-1:SpectecTerminal) .
```


### 55.64. `Instr_ok/table.init`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:395)

**SpecTec**


```spectec
rule Instr_ok/table.init:
  C |- TABLE.INIT x y : at I32 I32 -> eps
  -- if C.TABLES[x] = at lim rt_1
  -- if C.ELEMS[y] = rt_2
  -- Reftype_sub: C |- rt_2 <: rt_1
```

**의미**

table 주소 타입과 원소 참조 타입을 문맥에서 읽어 명령어의 번호·값·결과 타입을 확인한다.

정확한 stack 변화는 결론의 `at I32 I32 -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Reftype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, TABLE.INIT(X4:Nat, Y:Nat), (AT:SpectecTerminal (I32 I32)) ->- eps  eps) = true
  if typecheck(AT:SpectecTerminal, addrtype)
    /\ tuple(AT:SpectecTerminal (LIM:SpectecTerminal RT-1:SpectecTerminal)) := (C:SpectecTerminal . 'TABLES) [ X4:Nat ]
    /\ RT-2:SpectecTerminal := (C:SpectecTerminal . 'ELEMS) [ Y:Nat ]
    /\ Reftype-sub(C:SpectecTerminal, RT-2:SpectecTerminal, RT-1:SpectecTerminal) .
```


### 55.65. `Instr_ok/elem.drop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:401)

**SpecTec**


```spectec
rule Instr_ok/elem.drop:
  C |- ELEM.DROP x : eps -> eps
  -- if C.ELEMS[x] = rt
```

**의미**

element 번호가 존재해야 한다. operand stack은 바꾸지 않는다.

정확한 stack 변화는 결론의 `eps -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, ELEM.DROP(X4:Nat), eps ->- eps  eps) = true
  if RT:SpectecTerminal := (C:SpectecTerminal . 'ELEMS) [ X4:Nat ] .
```


### 55.66. `Instr_ok/memory.size`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:416)

**SpecTec**


```spectec
rule Instr_ok/memory.size:
  C |- MEMORY.SIZE x : eps -> at
  -- if C.MEMS[x] = at lim PAGE
```

**의미**

memory의 주소 타입을 문맥에서 읽어 주소·길이·반환값 타입을 확인한다.

정확한 stack 변화는 결론의 `eps -> at`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, MEMORY.SIZE(X4:Nat), eps ->- eps  AT:SpectecTerminal) = true
  if typecheck(AT:SpectecTerminal, addrtype)
    /\ __PAGE(AT:SpectecTerminal, LIM:SpectecTerminal) := (C:SpectecTerminal . 'MEMS) [ X4:Nat ] .
```


### 55.67. `Instr_ok/memory.grow`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:420)

**SpecTec**


```spectec
rule Instr_ok/memory.grow:
  C |- MEMORY.GROW x : at -> at
  -- if C.MEMS[x] = at lim PAGE
```

**의미**

memory의 주소 타입을 문맥에서 읽어 주소·길이·반환값 타입을 확인한다.

정확한 stack 변화는 결론의 `at -> at`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, MEMORY.GROW(X4:Nat), AT:SpectecTerminal ->- eps  AT:SpectecTerminal) = true
  if typecheck(AT:SpectecTerminal, addrtype)
    /\ typecheck(AT:SpectecTerminal, addrtype)
    /\ __PAGE(AT:SpectecTerminal, LIM:SpectecTerminal) := (C:SpectecTerminal . 'MEMS) [ X4:Nat ] .
```


### 55.68. `Instr_ok/memory.fill`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:424)

**SpecTec**


```spectec
rule Instr_ok/memory.fill:
  C |- MEMORY.FILL x : at I32 at -> eps
  -- if C.MEMS[x] = at lim PAGE
```

**의미**

memory의 주소 타입을 문맥에서 읽어 주소·길이·반환값 타입을 확인한다.

정확한 stack 변화는 결론의 `at I32 at -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, MEMORY.FILL(X4:Nat), (AT:SpectecTerminal (I32 AT:SpectecTerminal)) ->- eps  eps) = true
  if typecheck(AT:SpectecTerminal, addrtype)
    /\ typecheck(AT:SpectecTerminal, addrtype)
    /\ __PAGE(AT:SpectecTerminal, LIM:SpectecTerminal) := (C:SpectecTerminal . 'MEMS) [ X4:Nat ] .
```


### 55.69. `Instr_ok/memory.copy`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:428)

**SpecTec**


```spectec
rule Instr_ok/memory.copy:
  C |- MEMORY.COPY x_1 x_2 : at_1 at_2 $minat(at_1, at_2) -> eps
  -- if C.MEMS[x_1] = at_1 lim_1 PAGE
  -- if C.MEMS[x_2] = at_2 lim_2 PAGE
```

**의미**

memory의 주소 타입을 문맥에서 읽어 주소·길이·반환값 타입을 확인한다.

정확한 stack 변화는 결론의 `at_1 at_2 $minat(at_1, at_2) -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, MEMORY.COPY(X-1:Nat, X-23:Nat), (AT-1:SpectecTerminal (AT-2:SpectecTerminal INPUT-FIELD:SpectecTerminal)) ->- eps  eps) = true
  if typecheck(AT-1:SpectecTerminal, addrtype)
    /\ typecheck(AT-2:SpectecTerminal, addrtype)
    /\ typecheck(INPUT-FIELD:SpectecTerminal, addrtype)
    /\ minat(AT-1:SpectecTerminal, AT-2:SpectecTerminal) = INPUT-FIELD:SpectecTerminal
    /\ __PAGE(AT-1:SpectecTerminal, LIM-1:SpectecTerminal) := (C:SpectecTerminal . 'MEMS) [ X-1:Nat ]
    /\ __PAGE(AT-2:SpectecTerminal, LIM-2:SpectecTerminal) := (C:SpectecTerminal . 'MEMS) [ X-23:Nat ] .
```


### 55.70. `Instr_ok/memory.init`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:433)

**SpecTec**


```spectec
rule Instr_ok/memory.init:
  C |- MEMORY.INIT x y : at I32 I32 -> eps
  -- if C.MEMS[x] = at lim PAGE
  -- if C.DATAS[y] = OK
```

**의미**

memory의 주소 타입을 문맥에서 읽어 주소·길이·반환값 타입을 확인한다.

정확한 stack 변화는 결론의 `at I32 I32 -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, MEMORY.INIT(X4:Nat, Y:Nat), (AT:SpectecTerminal (I32 I32)) ->- eps  eps) = true
  if typecheck(AT:SpectecTerminal, addrtype)
    /\ __PAGE(AT:SpectecTerminal, LIM:SpectecTerminal) := (C:SpectecTerminal . 'MEMS) [ X4:Nat ]
    /\ ((C:SpectecTerminal . 'DATAS) [ Y:Nat ]) == OK .
```


### 55.71. `Instr_ok/data.drop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:438)

**SpecTec**


```spectec
rule Instr_ok/data.drop:
  C |- DATA.DROP x : eps -> eps
  -- if C.DATAS[x] = OK
```

**의미**

data 번호가 존재해야 한다. operand stack은 바꾸지 않는다.

정확한 stack 변화는 결론의 `eps -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, DATA.DROP(X4:Nat), eps ->- eps  eps) = true
  if ((C:SpectecTerminal . 'DATAS) [ X4:Nat ]) == OK .
```


### 55.72. `Instr_ok/load-val`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:451)

**SpecTec**


```spectec
rule Instr_ok/load-val:
  C |- LOAD nt x memarg : at -> nt
  -- if C.MEMS[x] = at lim PAGE
  -- Memarg_ok: |- memarg : at -> $size(nt)
```

**의미**

memory의 주소 타입과 읽을 값/packed 폭을 확인하고 Memarg_ok로 offset·alignment를 검사한다.

정확한 stack 변화는 결론의 `at -> nt`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Memarg_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, LOAD(NT:SpectecTerminal, eps, X4:Nat, MEMARG:SpectecTerminal), AT:SpectecTerminal ->- eps  NT:SpectecTerminal) = true
  if typecheck(AT:SpectecTerminal, addrtype)
    /\ typecheck(NT:SpectecTerminal, numtype)
    /\ __PAGE(AT:SpectecTerminal, LIM:SpectecTerminal) := (C:SpectecTerminal . 'MEMS) [ X4:Nat ]
    /\ Memarg-ok(MEMARG:SpectecTerminal, AT:SpectecTerminal, size(NT:SpectecTerminal)) .
```


### 55.73. `Instr_ok/load-pack`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:456)

**SpecTec**


```spectec
rule Instr_ok/load-pack:
  C |- LOAD Inn (M _ sx) x memarg : at -> Inn
  -- if C.MEMS[x] = at lim PAGE
  -- Memarg_ok: |- memarg : at -> M
```

**의미**

memory의 주소 타입과 읽을 값/packed 폭을 확인하고 Memarg_ok로 offset·alignment를 검사한다.

정확한 stack 변화는 결론의 `at -> Inn`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Memarg_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, LOAD(INN:SpectecTerminal, spectec-_-_(M2:Nat, SX:SpectecTerminal) ?, X4:Nat, MEMARG:SpectecTerminal), AT:SpectecTerminal ->- eps  INN:SpectecTerminal) = true
  if typecheck(INN:SpectecTerminal, addrtype)
    /\ typecheck(AT:SpectecTerminal, addrtype)
    /\ typecheck(INN:SpectecTerminal, addrtype)
    /\ __PAGE(AT:SpectecTerminal, LIM:SpectecTerminal) := (C:SpectecTerminal . 'MEMS) [ X4:Nat ]
    /\ Memarg-ok(MEMARG:SpectecTerminal, AT:SpectecTerminal, M2:Nat) .
```


### 55.74. `Instr_ok/store-val`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:470)

**SpecTec**


```spectec
rule Instr_ok/store-val:
  C |- STORE nt x memarg : at nt -> eps
  -- if C.MEMS[x] = at lim PAGE
  -- Memarg_ok: |- memarg : at -> $size(nt)
```

**의미**

memory의 주소 타입과 저장할 값/packed 폭을 확인하고 Memarg_ok로 offset·alignment를 검사한다.

정확한 stack 변화는 결론의 `at nt -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Memarg_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, STORE(NT:SpectecTerminal, eps, X4:Nat, MEMARG:SpectecTerminal), (AT:SpectecTerminal NT:SpectecTerminal) ->- eps  eps) = true
  if typecheck(AT:SpectecTerminal, addrtype)
    /\ typecheck(NT:SpectecTerminal, numtype)
    /\ __PAGE(AT:SpectecTerminal, LIM:SpectecTerminal) := (C:SpectecTerminal . 'MEMS) [ X4:Nat ]
    /\ Memarg-ok(MEMARG:SpectecTerminal, AT:SpectecTerminal, size(NT:SpectecTerminal)) .
```


### 55.75. `Instr_ok/store-pack`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:475)

**SpecTec**


```spectec
rule Instr_ok/store-pack:
  C |- STORE Inn M x memarg : at Inn -> eps
  -- if C.MEMS[x] = at lim PAGE
  -- Memarg_ok: |- memarg : at -> M
```

**의미**

memory의 주소 타입과 저장할 값/packed 폭을 확인하고 Memarg_ok로 offset·alignment를 검사한다.

정확한 stack 변화는 결론의 `at Inn -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Memarg_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, STORE(INN:SpectecTerminal, M2:Nat ?, X4:Nat, MEMARG:SpectecTerminal), (AT:SpectecTerminal INN:SpectecTerminal) ->- eps  eps) = true
  if typecheck(INN:SpectecTerminal, addrtype)
    /\ typecheck(AT:SpectecTerminal, addrtype)
    /\ typecheck(INN:SpectecTerminal, addrtype)
    /\ __PAGE(AT:SpectecTerminal, LIM:SpectecTerminal) := (C:SpectecTerminal . 'MEMS) [ X4:Nat ]
    /\ Memarg-ok(MEMARG:SpectecTerminal, AT:SpectecTerminal, M2:Nat) .
```


### 55.76. `Instr_ok/vload-val`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:480)

**SpecTec**


```spectec
rule Instr_ok/vload-val:
  C |- VLOAD V128 x memarg : at -> V128
  -- if C.MEMS[x] = at lim PAGE
  -- Memarg_ok: |- memarg : at -> $vsize(V128)
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `at -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Memarg_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, VLOAD(V128, eps, X4:Nat, MEMARG:SpectecTerminal), AT:SpectecTerminal ->- eps  V128) = true
  if typecheck(AT:SpectecTerminal, addrtype)
    /\ __PAGE(AT:SpectecTerminal, LIM:SpectecTerminal) := (C:SpectecTerminal . 'MEMS) [ X4:Nat ]
    /\ Memarg-ok(MEMARG:SpectecTerminal, AT:SpectecTerminal, vsize(V128)) .
```


### 55.77. `Instr_ok/vload-pack`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:485)

**SpecTec**


```spectec
rule Instr_ok/vload-pack:
  C |- VLOAD V128 (SHAPE M X N _ sx) x memarg : at -> V128
  -- if C.MEMS[x] = at lim PAGE
  -- Memarg_ok: |- memarg : at -> $(M*N)
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `at -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Memarg_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, VLOAD(V128, SHAPE_X_-_(M2:Nat, N2:Nat, SX:SpectecTerminal) ?, X4:Nat, MEMARG:SpectecTerminal), AT:SpectecTerminal ->- eps  V128) = true
  if typecheck(AT:SpectecTerminal, addrtype)
    /\ __PAGE(AT:SpectecTerminal, LIM:SpectecTerminal) := (C:SpectecTerminal . 'MEMS) [ X4:Nat ]
    /\ Memarg-ok(MEMARG:SpectecTerminal, AT:SpectecTerminal, M2:Nat * N2:Nat) .
```


### 55.78. `Instr_ok/vload-splat`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:490)

**SpecTec**


```spectec
rule Instr_ok/vload-splat:
  C |- VLOAD V128 (SPLAT N) x memarg : at -> V128
  -- if C.MEMS[x] = at lim PAGE
  -- Memarg_ok: |- memarg : at -> N
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `at -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Memarg_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, VLOAD(V128, SPLAT(N2:Nat) ?, X4:Nat, MEMARG:SpectecTerminal), AT:SpectecTerminal ->- eps  V128) = true
  if typecheck(AT:SpectecTerminal, addrtype)
    /\ __PAGE(AT:SpectecTerminal, LIM:SpectecTerminal) := (C:SpectecTerminal . 'MEMS) [ X4:Nat ]
    /\ Memarg-ok(MEMARG:SpectecTerminal, AT:SpectecTerminal, N2:Nat) .
```


### 55.79. `Instr_ok/vload-zero`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:495)

**SpecTec**


```spectec
rule Instr_ok/vload-zero:
  C |- VLOAD V128 (ZERO N) x memarg : at -> V128
  -- if C.MEMS[x] = at lim PAGE
  -- Memarg_ok: |- memarg : at -> N
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `at -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Memarg_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, VLOAD(V128, spectec-ZERO(N2:Nat) ?, X4:Nat, MEMARG:SpectecTerminal), AT:SpectecTerminal ->- eps  V128) = true
  if typecheck(AT:SpectecTerminal, addrtype)
    /\ __PAGE(AT:SpectecTerminal, LIM:SpectecTerminal) := (C:SpectecTerminal . 'MEMS) [ X4:Nat ]
    /\ Memarg-ok(MEMARG:SpectecTerminal, AT:SpectecTerminal, N2:Nat) .
```


### 55.80. `Instr_ok/vload_lane`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:500)

**SpecTec**


```spectec
rule Instr_ok/vload_lane:
  C |- VLOAD_LANE V128 N x memarg i : at V128 -> V128
  -- if C.MEMS[x] = at lim PAGE
  -- Memarg_ok: |- memarg : at -> N
  -- if $(i < 128/N)
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `at V128 -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Memarg_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, VLOAD-LANE(V128, N2:Nat, X4:Nat, MEMARG:SpectecTerminal, I:Nat), (AT:SpectecTerminal V128) ->- eps  V128) = true
  if typecheck(AT:SpectecTerminal, addrtype)
    /\ __PAGE(AT:SpectecTerminal, LIM:SpectecTerminal) := (C:SpectecTerminal . 'MEMS) [ X4:Nat ]
    /\ Memarg-ok(MEMARG:SpectecTerminal, AT:SpectecTerminal, N2:Nat)
    /\ (I:Nat : nat <:> rat) < ((128 : nat <:> rat) / (N2:Nat : nat <:> rat)) .
```


### 55.81. `Instr_ok/vstore`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:506)

**SpecTec**


```spectec
rule Instr_ok/vstore:
  C |- VSTORE V128 x memarg : at V128 -> eps
  -- if C.MEMS[x] = at lim PAGE
  -- Memarg_ok: |- memarg : at -> $vsize(V128)
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `at V128 -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Memarg_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, VSTORE(V128, X4:Nat, MEMARG:SpectecTerminal), (AT:SpectecTerminal V128) ->- eps  eps) = true
  if typecheck(AT:SpectecTerminal, addrtype)
    /\ __PAGE(AT:SpectecTerminal, LIM:SpectecTerminal) := (C:SpectecTerminal . 'MEMS) [ X4:Nat ]
    /\ Memarg-ok(MEMARG:SpectecTerminal, AT:SpectecTerminal, vsize(V128)) .
```


### 55.82. `Instr_ok/vstore_lane`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:511)

**SpecTec**


```spectec
rule Instr_ok/vstore_lane:
  C |- VSTORE_LANE V128 N x memarg i : at V128 -> eps
  -- if C.MEMS[x] = at lim PAGE
  -- Memarg_ok: |- memarg : at -> N
  -- if $(i < 128/N)
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `at V128 -> eps`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

이 rule이 직접 호출하는 relation: `Memarg_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, VSTORE-LANE(V128, N2:Nat, X4:Nat, MEMARG:SpectecTerminal, I:Nat), (AT:SpectecTerminal V128) ->- eps  eps) = true
  if typecheck(AT:SpectecTerminal, addrtype)
    /\ __PAGE(AT:SpectecTerminal, LIM:SpectecTerminal) := (C:SpectecTerminal . 'MEMS) [ X4:Nat ]
    /\ Memarg-ok(MEMARG:SpectecTerminal, AT:SpectecTerminal, N2:Nat)
    /\ (I:Nat : nat <:> rat) < ((128 : nat <:> rat) / (N2:Nat : nat <:> rat)) .
```


### 55.83. `Instr_ok/const`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:520)

**SpecTec**


```spectec
rule Instr_ok/const:
  C |- CONST nt c_nt : eps -> nt
```

**의미**

CONST의 숫자 타입에 맞는 literal을 받아 그 숫자 타입 하나를 stack에 남긴다.

정확한 stack 변화는 결론의 `eps -> nt`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, CONST(NT:SpectecTerminal, C-NT:SpectecTerminal), eps ->- eps  NT:SpectecTerminal) = true
  if typecheck(NT:SpectecTerminal, numtype) .
```


### 55.84. `Instr_ok/unop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:523)

**SpecTec**


```spectec
rule Instr_ok/unop:
  C |- UNOP nt unop_nt : nt -> nt
```

**의미**

숫자 단항 연산의 입력·결과 타입을 확인한다.

정확한 stack 변화는 결론의 `nt -> nt`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, UNOP(NT:SpectecTerminal, UNOP-NT:SpectecTerminal), NT:SpectecTerminal ->- eps  NT:SpectecTerminal) = true
  if typecheck(NT:SpectecTerminal, numtype)
    /\ typecheck(NT:SpectecTerminal, numtype) .
```


### 55.85. `Instr_ok/binop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:526)

**SpecTec**


```spectec
rule Instr_ok/binop:
  C |- BINOP nt binop_nt : nt nt -> nt
```

**의미**

숫자 이항 연산의 두 입력·결과 타입을 확인한다.

정확한 stack 변화는 결론의 `nt nt -> nt`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, BINOP(NT:SpectecTerminal, BINOP-NT:SpectecTerminal), (NT:SpectecTerminal NT:SpectecTerminal) ->- eps  NT:SpectecTerminal) = true
  if typecheck(NT:SpectecTerminal, numtype)
    /\ typecheck(NT:SpectecTerminal, numtype)
    /\ typecheck(NT:SpectecTerminal, numtype) .
```


### 55.86. `Instr_ok/testop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:529)

**SpecTec**


```spectec
rule Instr_ok/testop:
  C |- TESTOP nt testop_nt : nt -> I32
```

**의미**

단항 숫자 test의 operand 타입을 소비하고 I32 판정값을 남긴다.

정확한 stack 변화는 결론의 `nt -> I32`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, TESTOP(NT:SpectecTerminal, TESTOP-NT:SpectecTerminal), NT:SpectecTerminal ->- eps  I32) = true
  if typecheck(NT:SpectecTerminal, numtype) .
```


### 55.87. `Instr_ok/relop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:532)

**SpecTec**


```spectec
rule Instr_ok/relop:
  C |- RELOP nt relop_nt : nt nt -> I32
```

**의미**

숫자 비교의 두 operand를 소비하고 I32 판정값을 남긴다.

정확한 stack 변화는 결론의 `nt nt -> I32`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, RELOP(NT:SpectecTerminal, RELOP-NT:SpectecTerminal), (NT:SpectecTerminal NT:SpectecTerminal) ->- eps  I32) = true
  if typecheck(NT:SpectecTerminal, numtype)
    /\ typecheck(NT:SpectecTerminal, numtype) .
```


### 55.88. `Instr_ok/cvtop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:535)

**SpecTec**


```spectec
rule Instr_ok/cvtop:
  C |- CVTOP nt_1 nt_2 cvtop : nt_2 -> nt_1
```

**의미**

숫자 변환의 source/target 타입과 관련 부호·폭 표시를 확인한다.

정확한 stack 변화는 결론의 `nt_2 -> nt_1`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, CVTOP(NT-1:SpectecTerminal, NT-2:SpectecTerminal, CVTOP2:SpectecTerminal), NT-2:SpectecTerminal ->- eps  NT-1:SpectecTerminal) = true
  if typecheck(NT-2:SpectecTerminal, numtype)
    /\ typecheck(NT-1:SpectecTerminal, numtype) .
```


### 55.89. `Instr_ok/vconst`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:541)

**SpecTec**


```spectec
rule Instr_ok/vconst:
  C |- VCONST V128 c : eps -> V128
```

**의미**

VCONST의 벡터 타입에 맞는 literal을 받아 벡터 타입 하나를 stack에 남긴다.

정확한 stack 변화는 결론의 `eps -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, VCONST(V128, C3:Nat), eps ->- eps  V128) = true .
```


### 55.90. `Instr_ok/vvunop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:544)

**SpecTec**


```spectec
rule Instr_ok/vvunop:
  C |- VVUNOP V128 vvunop : V128 -> V128
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `V128 -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, VVUNOP(V128, VVUNOP2:SpectecTerminal), V128 ->- eps  V128) = true .
```


### 55.91. `Instr_ok/vvbinop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:547)

**SpecTec**


```spectec
rule Instr_ok/vvbinop:
  C |- VVBINOP V128 vvbinop : V128 V128 -> V128
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `V128 V128 -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, VVBINOP(V128, VVBINOP2:SpectecTerminal), (V128 V128) ->- eps  V128) = true .
```


### 55.92. `Instr_ok/vvternop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:550)

**SpecTec**


```spectec
rule Instr_ok/vvternop:
  C |- VVTERNOP V128 vvternop : V128 V128 V128 -> V128
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `V128 V128 V128 -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, VVTERNOP(V128, VVTERNOP2:SpectecTerminal), (V128 (V128 V128)) ->- eps  V128) = true .
```


### 55.93. `Instr_ok/vvtestop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:553)

**SpecTec**


```spectec
rule Instr_ok/vvtestop:
  C |- VVTESTOP V128 vvtestop : V128 -> I32
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `V128 -> I32`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, VVTESTOP(V128, VVTESTOP2:SpectecTerminal), V128 ->- eps  I32) = true .
```


### 55.94. `Instr_ok/vunop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:556)

**SpecTec**


```spectec
rule Instr_ok/vunop:
  C |- VUNOP sh vunop : V128 -> V128
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `V128 -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, VUNOP(SH:SpectecTerminal, VUNOP2:SpectecTerminal), V128 ->- eps  V128) = true .
```


### 55.95. `Instr_ok/vbinop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:559)

**SpecTec**


```spectec
rule Instr_ok/vbinop:
  C |- VBINOP sh vbinop : V128 V128 -> V128
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `V128 V128 -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, VBINOP(SH:SpectecTerminal, VBINOP2:SpectecTerminal), (V128 V128) ->- eps  V128) = true .
```


### 55.96. `Instr_ok/vternop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:562)

**SpecTec**


```spectec
rule Instr_ok/vternop:
  C |- VTERNOP sh vternop : V128 V128 V128 -> V128
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `V128 V128 V128 -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, VTERNOP(SH:SpectecTerminal, VTERNOP2:SpectecTerminal), (V128 (V128 V128)) ->- eps  V128) = true .
```


### 55.97. `Instr_ok/vtestop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:565)

**SpecTec**


```spectec
rule Instr_ok/vtestop:
  C |- VTESTOP sh vtestop : V128 -> I32
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `V128 -> I32`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, VTESTOP(SH:SpectecTerminal, VTESTOP2:SpectecTerminal), V128 ->- eps  I32) = true .
```


### 55.98. `Instr_ok/vrelop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:568)

**SpecTec**


```spectec
rule Instr_ok/vrelop:
  C |- VRELOP sh vrelop : V128 V128 -> V128
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `V128 V128 -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, VRELOP(SH:SpectecTerminal, VRELOP2:SpectecTerminal), (V128 V128) ->- eps  V128) = true .
```


### 55.99. `Instr_ok/vshiftop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:571)

**SpecTec**


```spectec
rule Instr_ok/vshiftop:
  C |- VSHIFTOP sh vshiftop : V128 I32 -> V128
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `V128 I32 -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, VSHIFTOP(SH:SpectecTerminal, VSHIFTOP2:SpectecTerminal), (V128 I32) ->- eps  V128) = true .
```


### 55.100. `Instr_ok/vbitmask`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:574)

**SpecTec**


```spectec
rule Instr_ok/vbitmask:
  C |- VBITMASK sh : V128 -> I32
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `V128 -> I32`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, VBITMASK(SH:SpectecTerminal), V128 ->- eps  I32) = true .
```


### 55.101. `Instr_ok/vswizzlop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:577)

**SpecTec**


```spectec
rule Instr_ok/vswizzlop:
  C |- VSWIZZLOP sh vswizzlop : V128 V128 -> V128
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `V128 V128 -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, VSWIZZLOP(SH:SpectecTerminal, VSWIZZLOP2:SpectecTerminal), (V128 V128) ->- eps  V128) = true .
```


### 55.102. `Instr_ok/vshuffle`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:580)

**SpecTec**


```spectec
rule Instr_ok/vshuffle:
  C |- VSHUFFLE sh i* : V128 V128 -> V128
  -- (if $(i < 2*$dim(sh)))*
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `V128 V128 -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, VSHUFFLE(SH:SpectecTerminal, I-:SpectecTerminals), (V128 V128) ->- eps  V128) = true
  if iterpr-20(SH:SpectecTerminal, I-:SpectecTerminals) .
```


### 55.103. `Instr_ok/vsplat`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:584)

**SpecTec**


```spectec
rule Instr_ok/vsplat:
  C |- VSPLAT sh : $unpackshape(sh) -> V128
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `$unpackshape(sh) -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, VSPLAT(SH:SpectecTerminal), REL-INPUT3:SpectecTerminal) = true
  if unpackshape(SH:SpectecTerminal) ->- eps  V128 = REL-INPUT3:SpectecTerminal .
```


### 55.104. `Instr_ok/vextract_lane`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:587)

**SpecTec**


```spectec
rule Instr_ok/vextract_lane:
  C |- VEXTRACT_LANE sh sx? i : V128 -> $unpackshape(sh)
  -- if i < $dim(sh)
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `V128 -> $unpackshape(sh)`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, VEXTRACT-LANE(SH:SpectecTerminal, SX-:SpectecTerminals, I:Nat), REL-INPUT3:SpectecTerminal) = true
  if len(SX-:SpectecTerminals) <= 1
    /\ V128 ->- eps  unpackshape(SH:SpectecTerminal) = REL-INPUT3:SpectecTerminal
    /\ I:Nat < spectec-dim(SH:SpectecTerminal) .
```


### 55.105. `Instr_ok/vreplace_lane`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:591)

**SpecTec**


```spectec
rule Instr_ok/vreplace_lane:
  C |- VREPLACE_LANE sh i : V128 $unpackshape(sh) -> V128
  -- if i < $dim(sh)
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `V128 $unpackshape(sh) -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
ceq Instr-ok(C:SpectecTerminal, VREPLACE-LANE(SH:SpectecTerminal, I:Nat), REL-INPUT3:SpectecTerminal) = true
  if (V128 unpackshape(SH:SpectecTerminal)) ->- eps  V128 = REL-INPUT3:SpectecTerminal
    /\ I:Nat < spectec-dim(SH:SpectecTerminal) .
```


### 55.106. `Instr_ok/vextunop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:595)

**SpecTec**


```spectec
rule Instr_ok/vextunop:
  C |- VEXTUNOP sh_1 sh_2 vextunop : V128 -> V128
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `V128 -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, VEXTUNOP(SH-1:SpectecTerminal, SH-2:SpectecTerminal, VEXTUNOP2:SpectecTerminal), V128 ->- eps  V128) = true .
```


### 55.107. `Instr_ok/vextbinop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:598)

**SpecTec**


```spectec
rule Instr_ok/vextbinop:
  C |- VEXTBINOP sh_1 sh_2 vextbinop : V128 V128 -> V128
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `V128 V128 -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, VEXTBINOP(SH-1:SpectecTerminal, SH-2:SpectecTerminal, VEXTBINOP2:SpectecTerminal), (V128 V128) ->- eps  V128) = true .
```


### 55.108. `Instr_ok/vextternop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:601)

**SpecTec**


```spectec
rule Instr_ok/vextternop:
  C |- VEXTTERNOP sh_1 sh_2 vextternop : V128 V128 V128 -> V128
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `V128 V128 V128 -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, VEXTTERNOP(SH-1:SpectecTerminal, SH-2:SpectecTerminal, VEXTTERNOP2:SpectecTerminal), (V128 (V128 V128)) ->- eps  V128) = true .
```


### 55.109. `Instr_ok/vnarrow`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:604)

**SpecTec**


```spectec
rule Instr_ok/vnarrow:
  C |- VNARROW sh_1 sh_2 sx : V128 V128 -> V128
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `V128 V128 -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, VNARROW(SH-1:SpectecTerminal, SH-2:SpectecTerminal, SX:SpectecTerminal), (V128 V128) ->- eps  V128) = true .
```


### 55.110. `Instr_ok/vcvtop`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:607)

**SpecTec**


```spectec
rule Instr_ok/vcvtop:
  C |- VCVTOP sh_1 sh_2 vcvtop : V128 -> V128
```

**의미**

벡터 연산의 shape·lane·폭과 입력·결과 stack 타입을 확인한다.

정확한 stack 변화는 결론의 `V128 -> V128`다. 화살표 왼쪽은 소비하는 입력 타입, 오른쪽은 남기는 결과 타입이다. `->_(x*)`가 있으면 초기화 효과도 표시한다.

**Maude — 번역식 초안**


```maude
eq Instr-ok(C:SpectecTerminal, VCVTOP(SH-1:SpectecTerminal, SH-2:SpectecTerminal, VCVTOP2:SpectecTerminal), V128 ->- eps  V128) = true .
```


<a id="instrtype-ok"></a>

## 56. `Instrtype_ok`

입력·출력 값 타입 리스트가 올바르고 표시된 local 번호가 존재하는지 확인한다.

**SpecTec 선언**


```spectec
relation Instrtype_ok: context |- instrtype : OK    hint(name "K-instr")  hint(macro "%instrtype")
```

**Maude 선언**


```maude
op Instrtype-ok : SpectecTerminal SpectecTerminal ~> Bool .
```


### 56.1. `Instrtype_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:64)

**SpecTec**


```spectec
rule Instrtype_ok:
  C |- t_1* ->_(x*) t_2* : OK
  -- Resulttype_ok: C |- t_1* : OK
  -- Resulttype_ok: C |- t_2* : OK
  -- (if C.LOCALS[x] = lct)*
```

**의미**

입력·출력 값 타입 리스트가 올바르고 표시된 local 번호가 존재하는지 확인한다.

이 rule이 직접 호출하는 relation: `Resulttype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instrtype-ok(C:SpectecTerminal, T1:SpectecTerminals ->- XS:SpectecTerminals T2:SpectecTerminals) = true
  if Resulttype-ok(C:SpectecTerminal, T1:SpectecTerminals)
    /\ Resulttype-ok(C:SpectecTerminal, T2:SpectecTerminals)
    /\ local-indices-ok(C:SpectecTerminal, XS:SpectecTerminals) .
```


<a id="instrtype-sub"></a>

## 57. `Instrtype_sub`

입력은 반대 방향, 출력은 같은 방향으로 subtype을 검사하고 추가 초기화 요구가 이미 충족되는지 확인한다.

**SpecTec 선언**


```spectec
relation Instrtype_sub: context |- instrtype <: instrtype     hint(name "S-instr")  hint(macro "%instrtypematch")
```

**Maude 선언**


```maude
op Instrtype-sub : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 57.1. `Instrtype_sub`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:139)

**SpecTec**


```spectec
rule Instrtype_sub:
  C |- t_11* ->_(x_1*) t_12* <: t_21* ->_(x_2*) t_22*
  -- Resulttype_sub: C |- t_21* <: t_11*
  -- Resulttype_sub: C |- t_12* <: t_22*
  -- if x* = $setminus_(localidx, x_2*, x_1*)
  -- (if C.LOCALS[x] = SET t)*
```

**의미**

입력은 반대 방향, 출력은 같은 방향으로 subtype을 검사하고 추가 초기화 요구가 이미 충족되는지 확인한다.

이 rule이 직접 호출하는 relation: `Resulttype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Instrtype-sub(C:SpectecTerminal, T11:SpectecTerminals ->- X1:SpectecTerminals T12:SpectecTerminals, T21:SpectecTerminals ->- X2:SpectecTerminals T22:SpectecTerminals) = true
  if Resulttype-sub(C:SpectecTerminal, T21:SpectecTerminals, T11:SpectecTerminals)
    /\ Resulttype-sub(C:SpectecTerminal, T12:SpectecTerminals, T22:SpectecTerminals)
    /\ set-locals-ok(C:SpectecTerminal, setminus-(localidx, X2:SpectecTerminals, X1:SpectecTerminals)) .
```


<a id="resulttype-ok"></a>

## 58. `Resulttype_ok`

결과 타입 리스트의 모든 원소가 올바른 값 타입인지 확인한다.

**SpecTec 선언**


```spectec
relation Resulttype_ok: context |- resulttype : OK  hint(name "K-result") hint(macro "%resulttype")
```

**Maude 선언**


```maude
op Resulttype-ok : SpectecTerminal SpectecTerminals ~> Bool .
```


### 58.1. `Resulttype_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:60)

**SpecTec**


```spectec
rule Resulttype_ok:
  C |- t* : OK
  -- (Valtype_ok: C |- t : OK)*
```

**의미**

결과 타입 리스트의 모든 원소가 올바른 값 타입인지 확인한다.

이 rule이 직접 호출하는 relation: `Valtype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Resulttype-ok(C:SpectecTerminal, T-:SpectecTerminals) = true
  if iterpr-1(C:SpectecTerminal, T-:SpectecTerminals) .
```


<a id="subtype-ok"></a>

## 59. `Subtype_ok`

상위 타입 번호가 앞선 타입을 가리키고 FINAL이 아니며 구성 타입이 호환되는지 검사한다.

**SpecTec 선언**


```spectec
relation Subtype_ok: context |- subtype : oktypeidx     hint(name "K-sub")     hint(macro "%subtype")     hint(prosepp "for")
```

**Maude 선언**


```maude
op Subtype-ok : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 59.1. `Subtype_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:149)

**SpecTec**


```spectec
rule Subtype_ok:
  C |- SUB FINAL? (_IDX x)* comptype : OK(x_0)
  -- if |x*| <= 1
  -- (if x < x_0)*
  -- (if $unrolldt(C.TYPES[x]) = SUB yy* comptype')*
  ----
  -- Comptype_ok: C |- comptype : OK
  -- (Comptype_sub: C |- comptype <: comptype')*
```

**의미**

상위 타입 번호가 앞선 타입을 가리키고 FINAL이 아니며 구성 타입이 호환되는지 검사한다.

이 rule이 직접 호출하는 relation: `Comptype_ok`, `Comptype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**

상위 타입 리스트 길이가 최대 1이라는 원문 조건 때문에 빈 경우와 원소 하나인 경우를 나누었다. FINAL?는 `typecheck`와 길이 조건으로 검사한다.


```maude
ceq Subtype-ok(C:SpectecTerminal, SUB(FIN:SpectecTerminals, eps, CT:SpectecTerminal), spectec-OK(X0:Nat)) = true
  if typecheck(FIN:SpectecTerminals, final)
    /\ len(FIN:SpectecTerminals) <= 1
    /\ Comptype-ok(C:SpectecTerminal, CT:SpectecTerminal) .
ceq Subtype-ok(C:SpectecTerminal, SUB(FIN:SpectecTerminals, -IDX(X:Nat), CT:SpectecTerminal), spectec-OK(X0:Nat)) = true
  if typecheck(FIN:SpectecTerminals, final)
    /\ len(FIN:SpectecTerminals) <= 1
    /\ X:Nat < X0:Nat
    /\ SUB(eps, YYS:SpectecTerminals, PCT:SpectecTerminal) := unrolldt((C:SpectecTerminal . 'TYPES)[X:Nat])
    /\ Comptype-ok(C:SpectecTerminal, CT:SpectecTerminal)
    /\ Comptype-sub(C:SpectecTerminal, CT:SpectecTerminal, PCT:SpectecTerminal) .
```


<a id="numtype-ok"></a>

## 60. `Numtype_ok`

문법상 numtype인 I32/I64/F32/F64를 올바른 숫자 타입으로 인정한다.

**SpecTec 선언**


```spectec
relation Numtype_ok: context |- numtype : OK    hint(name "K-num")  hint(macro "%numtype")
```

**Maude 선언**


```maude
op Numtype-ok : SpectecTerminal SpectecTerminal ~> Bool .
```


### 60.1. `Numtype_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:14)

**SpecTec**


```spectec
rule Numtype_ok:
  C |- numtype : OK
```

**의미**

문법상 numtype인 I32/I64/F32/F64를 올바른 숫자 타입으로 인정한다.

**Maude — 번역식 초안**


```maude
eq Numtype-ok(C:SpectecTerminal, NUMTYPE:SpectecTerminal) = true .
```


<a id="vectype-ok"></a>

## 61. `Vectype_ok`

문법상 vectype인 V128을 올바른 벡터 타입으로 인정한다.

**SpecTec 선언**


```spectec
relation Vectype_ok: context |- vectype : OK    hint(name "K-vec")  hint(macro "%vectype")
```

**Maude 선언**


```maude
op Vectype-ok : SpectecTerminal SpectecTerminal ~> Bool .
```


### 61.1. `Vectype_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:17)

**SpecTec**


```spectec
rule Vectype_ok:
  C |- vectype : OK
```

**의미**

문법상 vectype인 V128을 올바른 벡터 타입으로 인정한다.

**Maude — 번역식 초안**


```maude
eq Vectype-ok(C:SpectecTerminal, VECTYPE:SpectecTerminal) = true .
```


<a id="rectype-ok2"></a>

## 62. `Rectype_ok2`

재귀 그룹 내부 번호 i부터 subtype을 순서대로 검사한다.

**SpecTec 선언**


```spectec
relation Rectype_ok2: context |- rectype : oktypenat    hint(name "K-rec2")    hint(macro "%rectypeext")  hint(prosepp "for")
```

**Maude 선언**


```maude
op Rectype-ok2 : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 62.1. `Rectype_ok2/empty`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:188)

**SpecTec**


```spectec
rule Rectype_ok2/empty:
  C |- REC eps : OK(i)
```

**의미**

빈 재귀 그룹은 현재 그룹 내부 번호 i에서 성공한다.

**Maude — 번역식 초안**


```maude
eq Rectype-ok2(C:SpectecTerminal, REC(eps), spectec-OK(I:Nat)) = true .
```


### 62.2. `Rectype_ok2/cons`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:191)

**SpecTec**


```spectec
rule Rectype_ok2/cons:
  C |- REC (subtype_1 subtype*) : OK(i)
  -- Subtype_ok2: C |- subtype_1 : OK(i)
  -- Rectype_ok2: C |- REC subtype* : OK($(i+1))
```

**의미**

첫 subtype을 내부 번호 i에서 검사하고 나머지는 i+1에서 검사한다.

이 rule이 직접 호출하는 relation: `Rectype_ok2`, `Subtype_ok2`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Rectype-ok2(C:SpectecTerminal, REC(SUBTYPE-1:SpectecTerminal SUBTYPE-:SpectecTerminals), spectec-OK(I:Nat)) = true
  if Subtype-ok2(C:SpectecTerminal, SUBTYPE-1:SpectecTerminal, spectec-OK(I:Nat))
    /\ Rectype-ok2(C:SpectecTerminal, REC(SUBTYPE-:SpectecTerminals), spectec-OK(I:Nat + 1)) .
```


<a id="numtype-sub"></a>

## 63. `Numtype_sub`

같은 숫자 타입끼리만 subtype 관계로 인정한다.

**SpecTec 선언**


```spectec
relation Numtype_sub: context |- numtype <: numtype    hint(name "S-num")  hint(macro "%numtypematch")
```

**Maude 선언**


```maude
op Numtype-sub : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 63.1. `Numtype_sub`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:13)

**SpecTec**


```spectec
rule Numtype_sub:
  C |- numtype <: numtype
```

**의미**

같은 숫자 타입끼리만 subtype 관계로 인정한다.

**Maude — 번역식 초안**


```maude
eq Numtype-sub(C:SpectecTerminal, NUMTYPE:SpectecTerminal, NUMTYPE:SpectecTerminal) = true .
```


<a id="vectype-sub"></a>

## 64. `Vectype_sub`

같은 벡터 타입끼리만 subtype 관계로 인정한다.

**SpecTec 선언**


```spectec
relation Vectype_sub: context |- vectype <: vectype    hint(name "S-vec")  hint(macro "%vectypematch")
```

**Maude 선언**


```maude
op Vectype-sub : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 64.1. `Vectype_sub`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:16)

**SpecTec**


```spectec
rule Vectype_sub:
  C |- vectype <: vectype
```

**의미**

같은 벡터 타입끼리만 subtype 관계로 인정한다.

**Maude — 번역식 초안**


```maude
eq Vectype-sub(C:SpectecTerminal, VECTYPE:SpectecTerminal, VECTYPE:SpectecTerminal) = true .
```


<a id="blocktype-ok"></a>

## 65. `Blocktype_ok`

block의 입력·결과 타입을 직접 준 값 타입 또는 타입 번호에서 얻는다.

**SpecTec 선언**


```spectec
relation Blocktype_ok: context |- blocktype : instrtype hint(name "K-block") hint(macro "%blocktype") hint(prosepp "as")
```

**Maude 선언**


```maude
op Blocktype-ok : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 65.1. `Blocktype_ok/valtype`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:44)

**SpecTec**


```spectec
rule Blocktype_ok/valtype:
  C |- _RESULT valtype? : eps -> valtype?
  -- (Valtype_ok: C |- valtype : OK)?
```

**의미**

직접 적은 선택적 결과 타입은 입력이 없고 결과가 없거나 하나인 block type이다.

이 rule이 직접 호출하는 relation: `Valtype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Blocktype-ok(C:SpectecTerminal, -RESULT(VALTYPE-2:SpectecTerminals), REL-INPUT3:SpectecTerminal) = true
  if len(VALTYPE-2:SpectecTerminals) <= 1
    /\ eps ->- eps  lift(VALTYPE-2:SpectecTerminals) = REL-INPUT3:SpectecTerminal
    /\ iterpr-16(C:SpectecTerminal, VALTYPE-2:SpectecTerminals) .
```


### 65.2. `Blocktype_ok/typeidx`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:48)

**SpecTec**


```spectec
rule Blocktype_ok/typeidx:
  C |- _IDX typeidx : t_1* -> t_2*
  -- Expand: C.TYPES[typeidx] ~~ FUNC t_1* -> t_2*
```

**의미**

타입 번호의 FUNC 타입을 펼쳐 block의 입력·결과 타입으로 사용한다.

이 rule이 직접 호출하는 relation: `Expand`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Blocktype-ok(C:SpectecTerminal, -IDX(TYPEIDX:Nat), T-1-:SpectecTerminals ->- eps  T-2-:SpectecTerminals) = true
  if FUNC T-1-:SpectecTerminals -> T-2-:SpectecTerminals = Expand((C:SpectecTerminal . 'TYPES) [ TYPEIDX:Nat ]) .
```


<a id="catch-ok"></a>

## 66. `Catch_ok`

catch 대상 tag의 예외 값들과 추가 예외 참조가 label이 받는 타입에 맞는지 검사한다.

**SpecTec 선언**


```spectec
relation Catch_ok: context |- catch : OK hint(name "T") hint(macro "%catch")
```

**Maude 선언**


```maude
op Catch-ok : SpectecTerminal SpectecTerminal ~> Bool .
```


### 66.1. `Catch_ok/catch`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:181)

**SpecTec**


```spectec
rule Catch_ok/catch:
  C |- CATCH x l : OK
  -- Expand: $as_deftype(C.TAGS[x]) ~~ FUNC t* -> eps
  -- Resulttype_sub: C |- t* <: C.LABELS[l]
```

**의미**

catch 대상 tag의 예외 값들과 추가 예외 참조가 label이 받는 타입에 맞는지 검사한다.

이 rule이 직접 호출하는 relation: `Expand`, `Resulttype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Catch-ok(C:SpectecTerminal, CATCH(X4:Nat, L:Nat)) = true
  if FUNC T-:SpectecTerminals -> eps := Expand(as-deftype((C:SpectecTerminal . 'TAGS) [ X4:Nat ]))
    /\ Resulttype-sub(C:SpectecTerminal, T-:SpectecTerminals, unseq((C:SpectecTerminal . 'LABELS) [ L:Nat ])) .
```


### 66.2. `Catch_ok/catch_ref`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:186)

**SpecTec**


```spectec
rule Catch_ok/catch_ref:
  C |- CATCH_REF x l : OK
  -- Expand: $as_deftype(C.TAGS[x]) ~~ FUNC t* -> eps
  -- Resulttype_sub: C |- t* (REF EXN) <: C.LABELS[l]
```

**의미**

catch 대상 tag의 예외 값들과 추가 예외 참조가 label이 받는 타입에 맞는지 검사한다.

이 rule이 직접 호출하는 relation: `Expand`, `Resulttype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Catch-ok(C:SpectecTerminal, CATCH-REF(X4:Nat, L:Nat)) = true
  if FUNC T-:SpectecTerminals -> eps := Expand(as-deftype((C:SpectecTerminal . 'TAGS) [ X4:Nat ]))
    /\ Resulttype-sub(C:SpectecTerminal, T-:SpectecTerminals REF(eps, EXN), unseq((C:SpectecTerminal . 'LABELS) [ L:Nat ])) .
```


### 66.3. `Catch_ok/catch_all`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:191)

**SpecTec**


```spectec
rule Catch_ok/catch_all:
  C |- CATCH_ALL l : OK
  -- Resulttype_sub: C |- eps <: C.LABELS[l]
```

**의미**

catch 대상 tag의 예외 값들과 추가 예외 참조가 label이 받는 타입에 맞는지 검사한다.

이 rule이 직접 호출하는 relation: `Resulttype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Catch-ok(C:SpectecTerminal, CATCH-ALL(L:Nat)) = true
  if Resulttype-sub(C:SpectecTerminal, eps, unseq((C:SpectecTerminal . 'LABELS) [ L:Nat ])) .
```


### 66.4. `Catch_ok/catch_all_ref`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:195)

**SpecTec**


```spectec
rule Catch_ok/catch_all_ref:
  C |- CATCH_ALL_REF l : OK
  -- Resulttype_sub: C |- (REF EXN) <: C.LABELS[l]
```

**의미**

catch 대상 tag의 예외 값들과 추가 예외 참조가 label이 받는 타입에 맞는지 검사한다.

이 rule이 직접 호출하는 relation: `Resulttype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Catch-ok(C:SpectecTerminal, CATCH-ALL-REF(L:Nat)) = true
  if Resulttype-sub(C:SpectecTerminal, REF(eps, EXN), unseq((C:SpectecTerminal . 'LABELS) [ L:Nat ])) .
```


<a id="memarg-ok"></a>

## 67. `Memarg_ok`

대상 주소 폭에 offset이 들어가며 alignment가 접근 폭을 넘지 않는지 검사한다.

**SpecTec 선언**


```spectec
relation Memarg_ok: |- memarg : addrtype -> N  hint(name "T-memarg") hint(macro "%memarg") hint(prose "%1 is valid for %2 and %3")
```

**Maude 선언**


```maude
op Memarg-ok : SpectecTerminal SpectecTerminal Nat ~> Bool .
```


### 67.1. `Memarg_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.3-validation.instructions.spectec:410)

**SpecTec**


```spectec
rule Memarg_ok:
  |- {ALIGN n, OFFSET m} : at -> N
  -- if $(2^n <= N/8)
  -- if $(m < 2^$size(at))
```

**의미**

대상 주소 폭에 offset이 들어가며 alignment가 접근 폭을 넘지 않는지 검사한다.

**Maude — 번역식 초안**


```maude
ceq Memarg-ok({ (field('ALIGN, N3:Nat) ; field('OFFSET, M3:Nat)) }, AT:SpectecTerminal, N2:Nat) = true
  if ((2 ^ N3:Nat) : nat <:> rat) <= ((N2:Nat : nat <:> rat) / (8 : nat <:> rat))
    /\ M3:Nat < (2 ^ size(AT:SpectecTerminal)) .
```


<a id="resulttype-sub"></a>

## 68. `Resulttype_sub`

두 타입 리스트를 같은 길이로 한 쌍씩 비교한다.

**SpecTec 선언**


```spectec
relation Resulttype_sub: context |- resulttype <: resulttype  hint(name "S-result") hint(macro "%resulttypematch")
```

**Maude 선언**


```maude
op Resulttype-sub : SpectecTerminal SpectecTerminals SpectecTerminals ~> Bool .
```


### 68.1. `Resulttype_sub`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:135)

**SpecTec**


```spectec
rule Resulttype_sub:
  C |- t_1* <: t_2*
  -- (Valtype_sub: C |- t_1 <: t_2)*
```

**의미**

두 타입 리스트를 같은 길이로 한 쌍씩 비교한다.

이 rule이 직접 호출하는 relation: `Valtype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Resulttype-sub(C:SpectecTerminal, T-1-:SpectecTerminals, T-2-:SpectecTerminals) = true
  if iterpr-8(C:SpectecTerminal, T-1-:SpectecTerminals, T-2-:SpectecTerminals) .
```


<a id="storagetype-sub"></a>

## 69. `Storagetype_sub`

일반 값 타입은 Valtype_sub, packed 타입은 같은 packed 타입인지 검사한다.

**SpecTec 선언**


```spectec
relation Storagetype_sub: context |- storagetype <: storagetype hint(name "S-storage") hint(macro "%storagetypematch")
```

**Maude 선언**


```maude
op Storagetype-sub : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 69.1. `Storagetype_sub/val`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:162)

**SpecTec**


```spectec
rule Storagetype_sub/val:
  C |- valtype_1 <: valtype_2
  -- Valtype_sub: C |- valtype_1 <: valtype_2
```

**의미**

일반 값 타입은 Valtype_sub, packed 타입은 같은 packed 타입인지 검사한다. 이 rule은 `val` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

이 rule이 직접 호출하는 relation: `Valtype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Storagetype-sub(C:SpectecTerminal, VALTYPE-1:SpectecTerminal, VALTYPE-22:SpectecTerminal) = true
  if typecheck(VALTYPE-1:SpectecTerminal, valtype)
    /\ typecheck(VALTYPE-22:SpectecTerminal, valtype)
    /\ Valtype-sub(C:SpectecTerminal, VALTYPE-1:SpectecTerminal, VALTYPE-22:SpectecTerminal) .
```


### 69.2. `Storagetype_sub/pack`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:166)

**SpecTec**


```spectec
rule Storagetype_sub/pack:
  C |- packtype_1 <: packtype_2
  -- Packtype_sub: C |- packtype_1 <: packtype_2
```

**의미**

일반 값 타입은 Valtype_sub, packed 타입은 같은 packed 타입인지 검사한다. 이 rule은 `pack` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

이 rule이 직접 호출하는 relation: `Packtype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Storagetype-sub(C:SpectecTerminal, PACKTYPE-1:SpectecTerminal, PACKTYPE-2:SpectecTerminal) = true
  if typecheck(PACKTYPE-1:SpectecTerminal, packtype)
    /\ typecheck(PACKTYPE-2:SpectecTerminal, packtype)
    /\ Packtype-sub(C:SpectecTerminal, PACKTYPE-1:SpectecTerminal, PACKTYPE-2:SpectecTerminal) .
```


<a id="comptype-ok"></a>

## 70. `Comptype_ok`

struct의 필드, array의 원소, 함수의 입력·결과 리스트가 올바른지 확인한다.

**SpecTec 선언**


```spectec
relation Comptype_ok: context |- comptype : OK          hint(name "K-comp")    hint(macro "%comptype")
```

**Maude 선언**


```maude
op Comptype-ok : SpectecTerminal SpectecTerminal ~> Bool .
```


### 70.1. `Comptype_ok/struct`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:135)

**SpecTec**


```spectec
rule Comptype_ok/struct:
  C |- STRUCT fieldtype* : OK
  -- (Fieldtype_ok: C |- fieldtype : OK)*
```

**의미**

struct의 필드, array의 원소, 함수의 입력·결과 리스트가 올바른지 확인한다. 이 rule은 `struct` 구성 타입을 처리한다.

이 rule이 직접 호출하는 relation: `Fieldtype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Comptype-ok(C:SpectecTerminal, spectec-STRUCT(FIELDTYPE-:SpectecTerminals)) = true
  if iterpr-2(C:SpectecTerminal, FIELDTYPE-:SpectecTerminals) .
```


### 70.2. `Comptype_ok/array`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:139)

**SpecTec**


```spectec
rule Comptype_ok/array:
  C |- ARRAY fieldtype : OK
  -- Fieldtype_ok: C |- fieldtype : OK
```

**의미**

struct의 필드, array의 원소, 함수의 입력·결과 리스트가 올바른지 확인한다. 이 rule은 `array` 구성 타입을 처리한다.

이 rule이 직접 호출하는 relation: `Fieldtype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Comptype-ok(C:SpectecTerminal, spectec-ARRAY(FIELDTYPE:SpectecTerminal)) = true
  if Fieldtype-ok(C:SpectecTerminal, FIELDTYPE:SpectecTerminal) .
```


### 70.3. `Comptype_ok/func`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:143)

**SpecTec**


```spectec
rule Comptype_ok/func:
  C |- FUNC t_1* -> t_2* : OK
  -- Resulttype_ok: C |- t_1* : OK
  -- Resulttype_ok: C |- t_2* : OK
```

**의미**

struct의 필드, array의 원소, 함수의 입력·결과 리스트가 올바른지 확인한다. 이 rule은 `func` 구성 타입을 처리한다.

이 rule이 직접 호출하는 relation: `Resulttype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Comptype-ok(C:SpectecTerminal, FUNC T-1-:SpectecTerminals -> T-2-:SpectecTerminals) = true
  if Resulttype-ok(C:SpectecTerminal, T-1-:SpectecTerminals)
    /\ Resulttype-ok(C:SpectecTerminal, T-2-:SpectecTerminals) .
```


<a id="comptype-sub"></a>

## 71. `Comptype_sub`

struct의 대응 필드, array 원소, 함수의 입력·결과 타입을 비교한다.

**SpecTec 선언**


```spectec
relation Comptype_sub: context |- comptype <: comptype  hint(name "S-comp")    hint(macro "%comptypematch")
```

**Maude 선언**


```maude
op Comptype-sub : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 71.1. `Comptype_sub/struct`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:181)

**SpecTec**


```spectec
rule Comptype_sub/struct:
  C |- STRUCT (ft_1* ft'_1*) <: STRUCT ft_2*
  -- (Fieldtype_sub: C |- ft_1 <: ft_2)*
```

**의미**

첫 struct가 두 번째 struct의 필드를 앞부분에 모두 제공하고, 대응 필드 타입이 각각 호환되면 인정한다. 첫 struct 뒤의 추가 필드는 허용한다.

이 rule이 직접 호출하는 relation: `Fieldtype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Comptype-sub(C:SpectecTerminal, spectec-STRUCT(FT-1-:SpectecTerminals FT--1-:SpectecTerminals), spectec-STRUCT(FT-2-:SpectecTerminals)) = true
  if iterpr-7(C:SpectecTerminal, FT-1-:SpectecTerminals, FT-2-:SpectecTerminals) .
```


### 71.2. `Comptype_sub/array`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:185)

**SpecTec**


```spectec
rule Comptype_sub/array:
  C |- ARRAY ft_1 <: ARRAY ft_2
  -- Fieldtype_sub: C |- ft_1 <: ft_2
```

**의미**

struct의 대응 필드, array 원소, 함수의 입력·결과 타입을 비교한다. 이 rule은 `array` 구성 타입을 처리한다.

이 rule이 직접 호출하는 relation: `Fieldtype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Comptype-sub(C:SpectecTerminal, spectec-ARRAY(FT-1:SpectecTerminal), spectec-ARRAY(FT-2:SpectecTerminal)) = true
  if Fieldtype-sub(C:SpectecTerminal, FT-1:SpectecTerminal, FT-2:SpectecTerminal) .
```


### 71.3. `Comptype_sub/func`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:189)

**SpecTec**


```spectec
rule Comptype_sub/func:
  C |- FUNC t_11* -> t_12* <: FUNC t_21* -> t_22*
  -- Resulttype_sub: C |- t_21* <: t_11*
  -- Resulttype_sub: C |- t_12* <: t_22*
```

**의미**

함수 입력 타입은 두 번째→첫 번째로, 결과 타입은 첫 번째→두 번째로 비교한다.

이 rule이 직접 호출하는 relation: `Resulttype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Comptype-sub(C:SpectecTerminal, FUNC T-11-:SpectecTerminals -> T-12-:SpectecTerminals, FUNC T-21-:SpectecTerminals -> T-22-:SpectecTerminals) = true
  if Resulttype-sub(C:SpectecTerminal, T-21-:SpectecTerminals, T-11-:SpectecTerminals)
    /\ Resulttype-sub(C:SpectecTerminal, T-12-:SpectecTerminals, T-22-:SpectecTerminals) .
```


<a id="subtype-ok2"></a>

## 72. `Subtype_ok2`

재귀 그룹 내 참조가 존재하고 앞선 재귀 번호를 사용하며 FINAL이 아닌 상위 타입과 호환되는지 검사한다.

**SpecTec 선언**


```spectec
relation Subtype_ok2: context |- subtype : oktypenat    hint(name "K-sub2")    hint(macro "%subtypeext")  hint(prosepp "for")
```

**Maude 선언**


```maude
op Subtype-ok2 : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 72.1. `Subtype_ok2`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:167)

**SpecTec**


```spectec
rule Subtype_ok2:
  C |- SUB FINAL? typeuse* comptype : OK(i)
  -- if |typeuse*| <= 1
  -- (Typeuse_ok: C |- typeuse : OK)*
  -- (if $before(typeuse, i))*
  ----
  -- (if $unrollht_(C, typeuse) = SUB typeuse'* comptype')*
  ----
  -- Comptype_ok: C |- comptype : OK
  -- (Comptype_sub: C |- comptype <: comptype')*
```

**의미**

재귀 그룹 내 참조가 존재하고 앞선 재귀 번호를 사용하며 FINAL이 아닌 상위 타입과 호환되는지 검사한다.

이 rule이 직접 호출하는 relation: `Comptype_ok`, `Comptype_sub`, `Typeuse_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**

상위 타입 리스트 길이가 최대 1이라는 원문 조건 때문에 빈 경우와 원소 하나인 경우를 나누었다. FINAL?는 `typecheck`와 길이 조건으로 검사한다.


```maude
ceq Subtype-ok2(C:SpectecTerminal, SUB(FIN:SpectecTerminals, eps, CT:SpectecTerminal), spectec-OK(I:Nat)) = true
  if typecheck(FIN:SpectecTerminals, final)
    /\ len(FIN:SpectecTerminals) <= 1
    /\ Comptype-ok(C:SpectecTerminal, CT:SpectecTerminal) .
ceq Subtype-ok2(C:SpectecTerminal, SUB(FIN:SpectecTerminals, TU:SpectecTerminal, CT:SpectecTerminal), spectec-OK(I:Nat)) = true
  if typecheck(FIN:SpectecTerminals, final)
    /\ len(FIN:SpectecTerminals) <= 1
    /\ Typeuse-ok(C:SpectecTerminal, TU:SpectecTerminal)
    /\ before(TU:SpectecTerminal, I:Nat)
    /\ SUB(eps, TUS:SpectecTerminals, PCT:SpectecTerminal) := unrollht-(C:SpectecTerminal, TU:SpectecTerminal)
    /\ Comptype-ok(C:SpectecTerminal, CT:SpectecTerminal)
    /\ Comptype-sub(C:SpectecTerminal, CT:SpectecTerminal, PCT:SpectecTerminal) .
```


<a id="packtype-sub"></a>

## 73. `Packtype_sub`

같은 packed 타입끼리만 subtype으로 인정한다.

**SpecTec 선언**


```spectec
relation Packtype_sub: context |- packtype <: packtype          hint(name "S-pack")    hint(macro "%packtypematch")
```

**Maude 선언**


```maude
op Packtype-sub : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 73.1. `Packtype_sub`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:158)

**SpecTec**


```spectec
rule Packtype_sub:
  C |- packtype <: packtype
```

**의미**

같은 packed 타입끼리만 subtype으로 인정한다.

**Maude — 번역식 초안**


```maude
eq Packtype-sub(C:SpectecTerminal, PACKTYPE:SpectecTerminal, PACKTYPE:SpectecTerminal) = true .
```


<a id="fieldtype-ok"></a>

## 74. `Fieldtype_ok`

MUT 유무와 관계없이 필드의 저장 타입이 올바른지 확인한다.

**SpecTec 선언**


```spectec
relation Fieldtype_ok: context |- fieldtype : OK        hint(name "K-field")   hint(macro "%fieldtype")
```

**Maude 선언**


```maude
op Fieldtype-ok : SpectecTerminal SpectecTerminal ~> Bool .
```


### 74.1. `Fieldtype_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:130)

**SpecTec**


```spectec
rule Fieldtype_ok:
  C |- MUT? storagetype : OK
  -- Storagetype_ok: C |- storagetype : OK
```

**의미**

MUT 유무와 관계없이 필드의 저장 타입이 올바른지 확인한다.

이 rule이 직접 호출하는 relation: `Storagetype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Fieldtype-ok(C:SpectecTerminal, tuple(seq(eps) ZT:SpectecTerminal)) = true
  if Storagetype-ok(C:SpectecTerminal, ZT:SpectecTerminal) .
ceq Fieldtype-ok(C:SpectecTerminal, tuple(seq(MUT ?) ZT:SpectecTerminal)) = true
  if Storagetype-ok(C:SpectecTerminal, ZT:SpectecTerminal) .
```


<a id="fieldtype-sub"></a>

## 75. `Fieldtype_sub`

읽기 전용 필드는 한 방향, 수정 가능한 필드는 양방향 저장 타입 호환을 확인한다.

**SpecTec 선언**


```spectec
relation Fieldtype_sub: context |- fieldtype <: fieldtype       hint(name "S-field")   hint(macro "%fieldtypematch")
```

**Maude 선언**


```maude
op Fieldtype-sub : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
```


### 75.1. `Fieldtype_sub/const`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:171)

**SpecTec**


```spectec
rule Fieldtype_sub/const:
  C |- zt_1 <: zt_2
  -- Storagetype_sub: C |- zt_1 <: zt_2
```

**의미**

읽기 전용 필드는 한 방향, 수정 가능한 필드는 양방향 저장 타입 호환을 확인한다.

이 rule이 직접 호출하는 relation: `Storagetype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Fieldtype-sub(C:SpectecTerminal, tuple(seq(eps) ZT-1:SpectecTerminal), tuple(seq(eps) ZT-2:SpectecTerminal)) = true
  if Storagetype-sub(C:SpectecTerminal, ZT-1:SpectecTerminal, ZT-2:SpectecTerminal) .
```


### 75.2. `Fieldtype_sub/var`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.2-validation.subtyping.spectec:175)

**SpecTec**


```spectec
rule Fieldtype_sub/var:
  C |- MUT zt_1 <: MUT zt_2
  -- Storagetype_sub: C |- zt_1 <: zt_2
  -- Storagetype_sub: C |- zt_2 <: zt_1
```

**의미**

수정 가능한 필드는 읽기와 쓰기를 모두 할 수 있어 저장 타입을 양방향으로 비교한다.

이 rule이 직접 호출하는 relation: `Storagetype_sub`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Fieldtype-sub(C:SpectecTerminal, tuple(seq(MUT ?) ZT-1:SpectecTerminal), tuple(seq(MUT ?) ZT-2:SpectecTerminal)) = true
  if Storagetype-sub(C:SpectecTerminal, ZT-1:SpectecTerminal, ZT-2:SpectecTerminal)
    /\ Storagetype-sub(C:SpectecTerminal, ZT-2:SpectecTerminal, ZT-1:SpectecTerminal) .
```


<a id="storagetype-ok"></a>

## 76. `Storagetype_ok`

일반 값 타입 또는 packed 타입이 올바른 저장 타입인지 확인한다.

**SpecTec 선언**


```spectec
relation Storagetype_ok: context |- storagetype : OK    hint(name "K-storage") hint(macro "%storagetype")
```

**Maude 선언**


```maude
op Storagetype-ok : SpectecTerminal SpectecTerminal ~> Bool .
```


### 76.1. `Storagetype_ok/val`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:122)

**SpecTec**


```spectec
rule Storagetype_ok/val:
  C |- valtype : OK
  -- Valtype_ok: C |- valtype : OK
```

**의미**

일반 값 타입 또는 packed 타입이 올바른 저장 타입인지 확인한다. 이 rule은 `val` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

이 rule이 직접 호출하는 relation: `Valtype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Storagetype-ok(C:SpectecTerminal, VALTYPE:SpectecTerminal) = true
  if typecheck(VALTYPE:SpectecTerminal, valtype)
    /\ Valtype-ok(C:SpectecTerminal, VALTYPE:SpectecTerminal) .
```


### 76.2. `Storagetype_ok/pack`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:126)

**SpecTec**


```spectec
rule Storagetype_ok/pack:
  C |- packtype : OK
  -- Packtype_ok: C |- packtype : OK
```

**의미**

일반 값 타입 또는 packed 타입이 올바른 저장 타입인지 확인한다. 이 rule은 `pack` 경우를 처리하며 아래 premise에 적힌 해당 종류의 검사로 연결한다.

이 rule이 직접 호출하는 relation: `Packtype_ok`. 정의는 위 인덱스에서 찾을 수 있다.

**Maude — 번역식 초안**


```maude
ceq Storagetype-ok(C:SpectecTerminal, PACKTYPE:SpectecTerminal) = true
  if typecheck(PACKTYPE:SpectecTerminal, packtype)
    /\ Packtype-ok(C:SpectecTerminal, PACKTYPE:SpectecTerminal) .
```


<a id="packtype-ok"></a>

## 77. `Packtype_ok`

문법상 packed 타입인 I8/I16을 올바른 packed 타입으로 인정한다.

**SpecTec 선언**


```spectec
relation Packtype_ok: context |- packtype : OK          hint(name "K-pack")    hint(macro "%packtype")
```

**Maude 선언**


```maude
op Packtype-ok : SpectecTerminal SpectecTerminal ~> Bool .
```


### 77.1. `Packtype_ok`

[SpecTec 원문](/Users/minsung/Dev/projects/Spec2Maude/spectec/wasm-3.0/2.1-validation.types.spectec:119)

**SpecTec**


```spectec
rule Packtype_ok:
  C |- packtype : OK
```

**의미**

문법상 packed 타입인 I8/I16을 올바른 packed 타입으로 인정한다.

**Maude — 번역식 초안**


```maude
eq Packtype-ok(C:SpectecTerminal, PACKTYPE:SpectecTerminal) = true .
```


## 공통 보조 코드

위 수동 식에서 사용하는 타입 읽기·record 구성·리스트 반복 보조 함수다. 별도 Wasm 의미를 만들어내는 실행 엔진은 아니다. 원문 record/list 조건의 표현을 읽기 쉽게 분리했다.


```maude
op ref-ok : SpectecTerminal val ~> SpectecTerminal .
op ref-ok-sub : SpectecTerminal val SpectecTerminal ~> Bool .
op externaddr-ok : SpectecTerminal SpectecTerminal ~> SpectecTerminal .
op externaddr-ok-sub : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .
op empty-context : -> SpectecTerminal .
op rec-context : SpectecTerminals -> SpectecTerminal .
op function-context : SpectecTerminals SpectecTerminals -> SpectecTerminal .
eq empty-context = { (field('TYPES, eps) ; field('TAGS, eps) ; field('GLOBALS, eps) ; field('MEMS, eps) ; field('TABLES, eps) ; field('FUNCS, eps) ; field('DATAS, eps) ; field('ELEMS, eps) ; field('LOCALS, eps) ; field('LABELS, eps) ; field('RETURN, eps) ; field('REFS, eps) ; field('RECS, eps)) } .
eq rec-context(STS:SpectecTerminals) = { (field('TYPES, eps) ; field('TAGS, eps) ; field('GLOBALS, eps) ; field('MEMS, eps) ; field('TABLES, eps) ; field('FUNCS, eps) ; field('DATAS, eps) ; field('ELEMS, eps) ; field('LOCALS, eps) ; field('LABELS, eps) ; field('RETURN, eps) ; field('REFS, eps) ; field('RECS, STS:SpectecTerminals)) } .
eq function-context(LCTS:SpectecTerminals, TS:SpectecTerminals) = { (field('TYPES, eps) ; field('TAGS, eps) ; field('GLOBALS, eps) ; field('MEMS, eps) ; field('TABLES, eps) ; field('FUNCS, eps) ; field('DATAS, eps) ; field('ELEMS, eps) ; field('LOCALS, LCTS:SpectecTerminals) ; field('LABELS, seq(TS:SpectecTerminals)) ; field('RETURN, seq(TS:SpectecTerminals) ?) ; field('REFS, eps) ; field('RECS, eps)) } .

op unpack-fields : SpectecTerminals ~> SpectecTerminals .
eq unpack-fields(eps) = eps .
eq unpack-fields(tuple(seq(MS:SpectecTerminals) ZT:SpectecTerminal) FTS:SpectecTerminals) = unpack(ZT:SpectecTerminal) unpack-fields(FTS:SpectecTerminals) .
op local-indices-ok : SpectecTerminal SpectecTerminals ~> Bool .
eq local-indices-ok(C:SpectecTerminal, eps) = true .
ceq local-indices-ok(C:SpectecTerminal, X:Nat XS:SpectecTerminals) = true
  if indexDefined(C:SpectecTerminal . 'LOCALS, X:Nat)
    /\ typecheck((C:SpectecTerminal . 'LOCALS)[X:Nat], localtype)
    /\ local-indices-ok(C:SpectecTerminal, XS:SpectecTerminals) .
op set-locals-ok : SpectecTerminal SpectecTerminals ~> Bool .
eq set-locals-ok(C:SpectecTerminal, eps) = true .
ceq set-locals-ok(C:SpectecTerminal, X:Nat XS:SpectecTerminals) = true
  if tuple(SET T:SpectecTerminal) := (C:SpectecTerminal . 'LOCALS)[X:Nat]
    /\ typecheck(T:SpectecTerminal, valtype)
    /\ set-locals-ok(C:SpectecTerminal, XS:SpectecTerminals) .
op set-types : SpectecTerminals -> SpectecTerminals .
eq set-types(eps) = eps .
eq set-types(T:SpectecTerminal TS:SpectecTerminals) = tuple(SET T:SpectecTerminal) set-types(TS:SpectecTerminals) .
op local-types : SpectecTerminal SpectecTerminals ~> SpectecTerminals .
eq local-types(C:SpectecTerminal, eps) = eps .
ceq local-types(C:SpectecTerminal, L:SpectecTerminal LS:SpectecTerminals) = LC:SpectecTerminal REST:SpectecTerminals
  if LC:SpectecTerminal := Local-ok(C:SpectecTerminal, L:SpectecTerminal)
    /\ REST:SpectecTerminals := local-types(C:SpectecTerminal, LS:SpectecTerminals) .

op label-context : SpectecTerminals -> SpectecTerminal .
eq label-context(TS:SpectecTerminals) = { (field('TYPES, eps) ; field('TAGS, eps) ; field('GLOBALS, eps) ; field('MEMS, eps) ; field('TABLES, eps) ; field('FUNCS, eps) ; field('DATAS, eps) ; field('ELEMS, eps) ; field('LOCALS, eps) ; field('LABELS, seq(TS:SpectecTerminals)) ; field('RETURN, eps) ; field('REFS, eps) ; field('RECS, eps)) } .

op local-value-types : SpectecTerminal SpectecTerminals ~> SpectecTerminals .
eq local-value-types(C:SpectecTerminal, eps) = eps .
ceq local-value-types(C:SpectecTerminal, X:Nat XS:SpectecTerminals) = T:SpectecTerminal TS:SpectecTerminals
  if tuple(INIT:SpectecTerminal T:SpectecTerminal) := (C:SpectecTerminal . 'LOCALS)[X:Nat]
    /\ typecheck(INIT:SpectecTerminal, init)
    /\ typecheck(T:SpectecTerminal, valtype)
    /\ TS:SpectecTerminals := local-value-types(C:SpectecTerminal, XS:SpectecTerminals) .
op catches-ok : SpectecTerminal SpectecTerminals ~> Bool .
eq catches-ok(C:SpectecTerminal, eps) = true .
ceq catches-ok(C:SpectecTerminal, CA:SpectecTerminal CS:SpectecTerminals) = true
  if Catch-ok(C:SpectecTerminal, CA:SpectecTerminal)
    /\ catches-ok(C:SpectecTerminal, CS:SpectecTerminals) .
```

## 반복 premise와 expression의 전체 보조 식

본문의 `iterpr-*`는 원문 반복 premise를 한 원소씩 검사하는 식이다. 둘 이상의 리스트가 나오면 같은 길이로 zip하며, 하나만 먼저 끝나면 성공하지 않는다. `map-*`는 원문 반복 expression의 결과를 순서대로 만든다. 아래 이름은 authoring probe의 source-derived Prescan 이름이며 production translator를 변경한 새 이름 계약은 아니다.

### `iterpr-1`


```maude
op iterpr-1 : SpectecTerminal SpectecTerminals ~> Bool .

eq iterpr-1(C:SpectecTerminal, eps) = true .

ceq iterpr-1(C:SpectecTerminal, T:SpectecTerminal TS:SpectecTerminals) = iterpr-1(C:SpectecTerminal, TS:SpectecTerminals)
  if Valtype-ok(C:SpectecTerminal, T:SpectecTerminal) .
```

### `iterpr-13`


```maude
op iterpr-13 : Nat Nat SpectecTerminals ~> Bool .

eq iterpr-13(N3:Nat, K3:Nat, eps) = true .

ceq iterpr-13(N3:Nat, K3:Nat, M3:Nat ?) = true
  if _and_(N3:Nat <= M3:Nat, M3:Nat <= K3:Nat) .
```

### `iterpr-14`


```maude
op iterpr-14 : SpectecTerminal SpectecTerminals SpectecTerminals ~> Bool .

eq iterpr-14(C:SpectecTerminal, eps, eps) = true .

ceq iterpr-14(C:SpectecTerminal, T:SpectecTerminal TS:SpectecTerminals, X4:Nat XS:SpectecTerminals) = iterpr-14(C:SpectecTerminal, TS:SpectecTerminals, XS:SpectecTerminals)
  if ((C:SpectecTerminal . 'LOCALS) [ X4:Nat ]) == tuple(SET T:SpectecTerminal) .
```

### `iterpr-15`


```maude
op iterpr-15 : Nat SpectecTerminals ~> Bool .

eq iterpr-15(M-12:Nat, eps) = true .

ceq iterpr-15(M-12:Nat, M-23:Nat ?) = true
  if M-12:Nat <= M-23:Nat .
```

### `iterpr-16`


```maude
op iterpr-16 : SpectecTerminal SpectecTerminals ~> Bool .

eq iterpr-16(C:SpectecTerminal, eps) = true .

ceq iterpr-16(C:SpectecTerminal, VALTYPE:SpectecTerminal ?) = true
  if Valtype-ok(C:SpectecTerminal, VALTYPE:SpectecTerminal) .
```

### `iterpr-17`


```maude
op iterpr-17 : SpectecTerminal SpectecTerminals SpectecTerminals ~> Bool .

eq iterpr-17(C:SpectecTerminal, T-:SpectecTerminals, eps) = true .

ceq iterpr-17(C:SpectecTerminal, T-:SpectecTerminals, L:Nat LS:SpectecTerminals) = iterpr-17(C:SpectecTerminal, T-:SpectecTerminals, LS:SpectecTerminals)
  if Resulttype-sub(C:SpectecTerminal, T-:SpectecTerminals, unseq((C:SpectecTerminal . 'LABELS) [ L:Nat ])) .
```

### `iterpr-18`


```maude
op iterpr-18 : SpectecTerminal SpectecTerminals ~> Bool .

eq iterpr-18(C:SpectecTerminal, eps) = true .

ceq iterpr-18(C:SpectecTerminal, CATCH2:SpectecTerminal CATCHS:SpectecTerminals) = iterpr-18(C:SpectecTerminal, CATCHS:SpectecTerminals)
  if Catch-ok(C:SpectecTerminal, CATCH2:SpectecTerminal) .
```

### `iterpr-19`


```maude
op iterpr-19 : SpectecTerminals ~> Bool .

eq iterpr-19(eps) = true .

ceq iterpr-19(ZT:SpectecTerminal ZTS:SpectecTerminals) = iterpr-19(ZTS:SpectecTerminals)
  if Defaultable(unpack(ZT:SpectecTerminal)) .
```

### `iterpr-2`


```maude
op iterpr-2 : SpectecTerminal SpectecTerminals ~> Bool .

eq iterpr-2(C:SpectecTerminal, eps) = true .

ceq iterpr-2(C:SpectecTerminal, FIELDTYPE:SpectecTerminal FIELDTYPES:SpectecTerminals) = iterpr-2(C:SpectecTerminal, FIELDTYPES:SpectecTerminals)
  if Fieldtype-ok(C:SpectecTerminal, FIELDTYPE:SpectecTerminal) .
```

### `iterpr-20`


```maude
op iterpr-20 : SpectecTerminal SpectecTerminals ~> Bool .

eq iterpr-20(SH:SpectecTerminal, eps) = true .

ceq iterpr-20(SH:SpectecTerminal, I:Nat IS:SpectecTerminals) = iterpr-20(SH:SpectecTerminal, IS:SpectecTerminals)
  if I:Nat < (2 * spectec-dim(SH:SpectecTerminal)) .
```

### `iterpr-21`


```maude
op iterpr-21 : SpectecTerminal SpectecTerminals SpectecTerminals SpectecTerminals ~> Bool .

eq iterpr-21(C:SpectecTerminal, eps, eps, eps) = true .

ceq iterpr-21(C:SpectecTerminal, INIT:SpectecTerminal INITS:SpectecTerminals, T:SpectecTerminal TS:SpectecTerminals, X-1:Nat X_1S:SpectecTerminals) = iterpr-21(C:SpectecTerminal, INITS:SpectecTerminals, TS:SpectecTerminals, X_1S:SpectecTerminals)
  if ((C:SpectecTerminal . 'LOCALS) [ X-1:Nat ]) == tuple(INIT:SpectecTerminal T:SpectecTerminal) .
```

### `iterpr-22`


```maude
op iterpr-22 : SpectecTerminal InstrList ~> Bool .

eq iterpr-22(C:SpectecTerminal, eps) = true .

ceq iterpr-22(C:SpectecTerminal, INSTR:instr INSTRS:InstrList) = iterpr-22(C:SpectecTerminal, INSTRS:InstrList)
  if Instr-const(C:SpectecTerminal, INSTR:instr) .
```

### `iterpr-23`


```maude
op iterpr-23 : SpectecTerminal SpectecTerminals SpectecTerminals ~> Bool .

eq iterpr-23(C:SpectecTerminal, eps, eps) = true .

ceq iterpr-23(C:SpectecTerminal, LCT2:SpectecTerminal LCTS:SpectecTerminals, LOCAL2:SpectecTerminal LOCALS:SpectecTerminals) = iterpr-23(C:SpectecTerminal, LCTS:SpectecTerminals, LOCALS:SpectecTerminals)
  if LCT2:SpectecTerminal = Local-ok(C:SpectecTerminal, LOCAL2:SpectecTerminal) .
```

### `iterpr-24`


```maude
op iterpr-24 : SpectecTerminal SpectecTerminal SpectecTerminals ~> Bool .

eq iterpr-24(C:SpectecTerminal, ELEMTYPE:SpectecTerminal, eps) = true .

ceq iterpr-24(C:SpectecTerminal, ELEMTYPE:SpectecTerminal, seq(EXPR:InstrList) EXPRS:SpectecTerminals) = iterpr-24(C:SpectecTerminal, ELEMTYPE:SpectecTerminal, EXPRS:SpectecTerminals)
  if Expr-ok-const(C:SpectecTerminal, EXPR:InstrList, ELEMTYPE:SpectecTerminal) .
```

### `iterpr-25`


```maude
op iterpr-25 : SpectecTerminals SpectecTerminals SpectecTerminals ~> Bool .

eq iterpr-25(DT--:SpectecTerminals, eps, eps) = true .

ceq iterpr-25(DT--:SpectecTerminals, IMPORT2:SpectecTerminal IMPORTS:SpectecTerminals, XT-I2:SpectecTerminal XT_IS:SpectecTerminals) = iterpr-25(DT--:SpectecTerminals, IMPORTS:SpectecTerminals, XT_IS:SpectecTerminals)
  if XT-I2:SpectecTerminal = Import-ok({ (field('TYPES, DT--:SpectecTerminals) ; (field('TAGS, eps) ; (field('GLOBALS, eps) ; (field('MEMS, eps) ; (field('TABLES, eps) ; (field('FUNCS, eps) ; (field('DATAS, eps) ; (field('ELEMS, eps) ; (field('LOCALS, eps) ; (field('LABELS, eps) ; (field('RETURN, eps) ; (field('REFS, eps) ; field('RECS, eps))))))))))))) }, IMPORT2:SpectecTerminal) .
```

### `iterpr-26`


```maude
op iterpr-26 : SpectecTerminal SpectecTerminals SpectecTerminals ~> Bool .

eq iterpr-26(C-:SpectecTerminal, eps, eps) = true .

ceq iterpr-26(C-:SpectecTerminal, JT:SpectecTerminal JTS:SpectecTerminals, TAG2:SpectecTerminal TAGS:SpectecTerminals) = iterpr-26(C-:SpectecTerminal, JTS:SpectecTerminals, TAGS:SpectecTerminals)
  if JT:SpectecTerminal = Tag-ok(C-:SpectecTerminal, TAG2:SpectecTerminal) .
```

### `iterpr-27`


```maude
op iterpr-27 : SpectecTerminal SpectecTerminals SpectecTerminals ~> Bool .

eq iterpr-27(C-:SpectecTerminal, eps, eps) = true .

ceq iterpr-27(C-:SpectecTerminal, MEM2:SpectecTerminal MEMS:SpectecTerminals, MT:SpectecTerminal MTS:SpectecTerminals) = iterpr-27(C-:SpectecTerminal, MEMS:SpectecTerminals, MTS:SpectecTerminals)
  if MT:SpectecTerminal = Mem-ok(C-:SpectecTerminal, MEM2:SpectecTerminal) .
```

### `iterpr-28`


```maude
op iterpr-28 : SpectecTerminal SpectecTerminals SpectecTerminals ~> Bool .

eq iterpr-28(C-:SpectecTerminal, eps, eps) = true .

ceq iterpr-28(C-:SpectecTerminal, TABLE2:SpectecTerminal TABLES:SpectecTerminals, TT:SpectecTerminal TTS:SpectecTerminals) = iterpr-28(C-:SpectecTerminal, TABLES:SpectecTerminals, TTS:SpectecTerminals)
  if TT:SpectecTerminal = Table-ok(C-:SpectecTerminal, TABLE2:SpectecTerminal) .
```

### `iterpr-29`


```maude
op iterpr-29 : SpectecTerminal SpectecTerminals SpectecTerminals ~> Bool .

eq iterpr-29(C:SpectecTerminal, eps, eps) = true .

ceq iterpr-29(C:SpectecTerminal, DT:SpectecTerminal DTS:SpectecTerminals, FUNC2:SpectecTerminal FUNCS:SpectecTerminals) = iterpr-29(C:SpectecTerminal, DTS:SpectecTerminals, FUNCS:SpectecTerminals)
  if DT:SpectecTerminal = Func-ok(C:SpectecTerminal, FUNC2:SpectecTerminal) .
```

### `iterpr-30`


```maude
op iterpr-30 : SpectecTerminal SpectecTerminals SpectecTerminals ~> Bool .

eq iterpr-30(C:SpectecTerminal, eps, eps) = true .

ceq iterpr-30(C:SpectecTerminal, DATA2:SpectecTerminal DATAS:SpectecTerminals, OK3:SpectecTerminal OKS:SpectecTerminals) = iterpr-30(C:SpectecTerminal, DATAS:SpectecTerminals, OKS:SpectecTerminals)
  if Data-ok(C:SpectecTerminal, DATA2:SpectecTerminal, OK3:SpectecTerminal) .
```

### `iterpr-31`


```maude
op iterpr-31 : SpectecTerminal SpectecTerminals SpectecTerminals ~> Bool .

eq iterpr-31(C:SpectecTerminal, eps, eps) = true .

ceq iterpr-31(C:SpectecTerminal, ELEM2:SpectecTerminal ELEMS:SpectecTerminals, RT:SpectecTerminal RTS:SpectecTerminals) = iterpr-31(C:SpectecTerminal, ELEMS:SpectecTerminals, RTS:SpectecTerminals)
  if RT:SpectecTerminal = Elem-ok(C:SpectecTerminal, ELEM2:SpectecTerminal) .
```

### `iterpr-32`


```maude
op iterpr-32 : SpectecTerminal SpectecTerminals ~> Bool .

eq iterpr-32(C:SpectecTerminal, eps) = true .

ceq iterpr-32(C:SpectecTerminal, START2:SpectecTerminal ?) = true
  if Start-ok(C:SpectecTerminal, START2:SpectecTerminal) .
```

### `iterpr-33`


```maude
op iterpr-33 : SpectecTerminal SpectecTerminals SpectecTerminals SpectecTerminals ~> Bool .

eq iterpr-33(C:SpectecTerminal, eps, eps, eps) = true .

ceq iterpr-33(C:SpectecTerminal, EXPORT2:SpectecTerminal EXPORTS:SpectecTerminals, seq(NM:SpectecTerminals) NMS:SpectecTerminals, XT-E2:SpectecTerminal XT_ES:SpectecTerminals) = iterpr-33(C:SpectecTerminal, EXPORTS:SpectecTerminals, NMS:SpectecTerminals, XT_ES:SpectecTerminals)
  if tuple(seq(NM:SpectecTerminals) XT-E2:SpectecTerminal) = Export-ok(C:SpectecTerminal, EXPORT2:SpectecTerminal) .
```

### `iterpr-7`


```maude
op iterpr-7 : SpectecTerminal SpectecTerminals SpectecTerminals ~> Bool .

eq iterpr-7(C:SpectecTerminal, eps, eps) = true .

ceq iterpr-7(C:SpectecTerminal, FT-1:SpectecTerminal FT_1S:SpectecTerminals, FT-2:SpectecTerminal FT_2S:SpectecTerminals) = iterpr-7(C:SpectecTerminal, FT_1S:SpectecTerminals, FT_2S:SpectecTerminals)
  if Fieldtype-sub(C:SpectecTerminal, FT-1:SpectecTerminal, FT-2:SpectecTerminal) .
```

### `iterpr-8`


```maude
op iterpr-8 : SpectecTerminal SpectecTerminals SpectecTerminals ~> Bool .

eq iterpr-8(C:SpectecTerminal, eps, eps) = true .

ceq iterpr-8(C:SpectecTerminal, T-12:SpectecTerminal T_1S:SpectecTerminals, T-22:SpectecTerminal T_2S:SpectecTerminals) = iterpr-8(C:SpectecTerminal, T_1S:SpectecTerminals, T_2S:SpectecTerminals)
  if Valtype-sub(C:SpectecTerminal, T-12:SpectecTerminal, T-22:SpectecTerminal) .
```

### `iterpr-9`


```maude
op iterpr-9 : SpectecTerminal SpectecTerminals SpectecTerminals ~> Bool .

eq iterpr-9(C:SpectecTerminal, eps, eps) = true .

ceq iterpr-9(C:SpectecTerminal, LCT2:SpectecTerminal LCTS:SpectecTerminals, X4:Nat XS:SpectecTerminals) = iterpr-9(C:SpectecTerminal, LCTS:SpectecTerminals, XS:SpectecTerminals)
  if ((C:SpectecTerminal . 'LOCALS) [ X4:Nat ]) == LCT2:SpectecTerminal .
```

### `map-exp-616`


```maude
op map-exp-616 : SpectecTerminals SpectecTerminals ~> SpectecTerminals .

eq map-exp-616(eps, eps) = eps .

eq map-exp-616(seq(MUT-:SpectecTerminals) MUT?S:SpectecTerminals, ZT:SpectecTerminal ZTS:SpectecTerminals) = tuple(seq(MUT-:SpectecTerminals) ZT:SpectecTerminal) map-exp-616(MUT?S:SpectecTerminals, ZTS:SpectecTerminals) .
```

### `map-exp-618`


```maude
op project-map-exp-618 : SpectecTerminals ~> SpectecTerminal .

eq project-map-exp-618(eps) = tuple(seq(eps) seq(eps)) .

ceq project-map-exp-618(tuple(seq(MUT-:SpectecTerminals) ZT:SpectecTerminal) PROJECT-REST:SpectecTerminals) = tuple(seq(seq(MUT-:SpectecTerminals) PROJECT-COLUMN-1:SpectecTerminals) seq(ZT:SpectecTerminal PROJECT-COLUMN-2:SpectecTerminals))
  if len(MUT-:SpectecTerminals) <= 1
    /\ tuple(seq(PROJECT-COLUMN-1:SpectecTerminals) seq(PROJECT-COLUMN-2:SpectecTerminals)) := project-map-exp-618(PROJECT-REST:SpectecTerminals) .
```

### `map-exp-656`


```maude
op map-exp-656 : SpectecTerminals ~> SpectecTerminals .

eq map-exp-656(eps) = eps .

eq map-exp-656(T:SpectecTerminal TS:SpectecTerminals) = tuple(SET T:SpectecTerminal) map-exp-656(TS:SpectecTerminals) .
```

### `map-exp-686`


```maude
op map-exp-686 : SpectecTerminals ~> SpectecTerminals .

eq map-exp-686(eps) = eps .

eq map-exp-686(T-12:SpectecTerminal T_1S:SpectecTerminals) = tuple(SET T-12:SpectecTerminal) map-exp-686(T_1S:SpectecTerminals) .
```

### `map-unpack`


```maude
op map-unpack : SpectecTerminals ~> SpectecTerminals .

eq map-unpack(eps) = eps .

eq map-unpack(ZT:SpectecTerminal ZTS:SpectecTerminals) = unpack(ZT:SpectecTerminal) map-unpack(ZTS:SpectecTerminals) .
```

## 확인 결과와 다음 구현의 범위

- 실제 IL의 `RecD/RelD/RuleD/RulePr`와 반복 premise를 방문하여 5개 root의 재귀 relation 의존성을 확인했다: 77개 relation, 283개 활성 rule. 각 원문 rule과 Maude 식을 모두 포함했다.
- 원문 의미와 조건을 검토하고, 현재 translator의 직접 lowering을 참고하여 274개 직접 식과 9개 추가 입력 검사식을 작성했다. 코드 생성용 임시 authoring probe를 사용했으나 production 자동화 기능을 개발하거나 원문 hint를 변경하지 않았다.
- companion `positive-clauses.maude`를 Maude 3.5.1에 load했으며 Warning/Error가 없었다. **load 성공은 전체 relation의 결정 절차가 완성됐다는 뜻이 아니다.**
- null/i31 기본 타입 계산, i31의 직접 타입 검사와 EQ로의 widening, nullable ANY 타입 검사가 확인됐다. 중간값 EQ를 명시한 I31 <: ANY 검사도 true였다.
- 반면 중간값을 주지 않은 `Heaptype-sub({}, I31, ANY)`는 미계산으로 남았다. i31를 struct로 검사한 경우도 false를 반환하는 완성된 결정 절차가 없어 미계산으로 남았다. 이를 거부 성공/PASS로 기록하지 않는다.
- 추가 확인에서 빈 struct 구성 타입의 Subtype-ok/Subtype-ok2, 해당 재귀 그룹의 Deftype-ok, 필드/global 타입 검사, unpack-fields, local-types 결과를 확인했다. 타입 번호가 없는 문맥의 Func-ok 호출은 미계산으로 남았다.
- `Module-ok-via-rule` 및 전체 함수 본문 검증의 실행·종료·보존은 확인하지 않았다.
- 기존 `relation-backends.maude`를 대체하려면 아홉 추가 입력 검사식의 연결 계산과 필요한 실패 판정을 완성하고, source의 성공·실패를 구별하는 실행 검증이 필요하다. 이 파일을 그대로 production에 넣고 backend를 삭제할 단계는 아니다.

## 재현 파일

확인용 코드와 로그:

- [positive-clauses.maude](/private/tmp/spec2maude-handbook-20260930/positive-clauses.maude)
- [load.maude](/private/tmp/spec2maude-handbook-20260930/load.maude)
- [load.log](/private/tmp/spec2maude-handbook-20260930/load.log)
- [smoke.maude](/private/tmp/spec2maude-handbook-20260930/smoke.maude)
- [smoke.log](/private/tmp/spec2maude-handbook-20260930/smoke.log)
- [manual-smoke.maude](/private/tmp/spec2maude-handbook-20260930/manual-smoke.maude)
- [manual-smoke.log](/private/tmp/spec2maude-handbook-20260930/manual-smoke.log)
- [manifest.tsv](/private/tmp/spec2maude-handbook-20260930/manifest.tsv)
- [coverage.json](/private/tmp/spec2maude-handbook-20260930/coverage.json)


검토 기준: repository HEAD `15d905fd34086c64aa856e4af39ca518841f5063`, SpecTec revision `acc6e834ff403c82554d081237f327346190ad96`. 기존 walkthrough의 dirty edit는 보존했다. production 코드·SpecTec 원문·backend·기존 문서는 수정하지 않았다.
