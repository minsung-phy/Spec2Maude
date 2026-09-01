# Maude sort/list 및 `Step/ctxt-instrs` 최적화 계획

> **Status:** agreed optimization design; this is not a description of behavior
> already implemented. Repository policy requires incorporating the approved
> steps into `docs/IMPLEMENTATION_PLAN_V2.md` before source implementation. For
> current installation and testing commands, see `INSTALL.md` and `ARTIFACT.md`.

## 0. 문서 목적과 범위

이 문서는 현재 Spec2Maude 변환기의 timeout 원인을 줄이기 위한 통합 작업 지침이다.

1. SpecTec의 `hint(maude_sort)`를 보고 중요한 syntax를 Maude sort로 만든다.
2. `hint(maude_subsort "...")`를 보고 필요한 subsort edge를 명시적으로 만든다.
3. 해당 syntax가 IL에서 `*` 또는 `+`로 사용됐는지 확인한다.
4. 사용된 경우 Maude Prelude의 `LIST{X :: TRIV}`를 이용해 전용 리스트를 만든다.
5. 기존의 일반적인 `x*`도 수동 `SpectecTerminals` 구현 대신 Prelude 리스트를 사용한다.
6. `hint(maude_context)`가 붙은 `Step/ctxt-instrs`를 focus 탐색, heating,
   direct-only 실행, cooling으로 변환한다.

두 최적화는 연결되어 있지만 역할은 다르다.

```text
sort/list 분리       flat sequence의 타입 정보를 Maude에 전달
focus/heat/fire/cool  ctxt-instrs의 반복적인 associative 분해를 직접 제어
```

따라서 typed list만 도입하거나 heating/cooling 모양만 추가한 것으로 timeout 해결을
주장하지 않는다. 마지막 단계에서 같은 suite 입력의 시간과 rewrite 수를 비교한다.

현재 저장소에는 `docs/IMPLEMENTATION_PLAN_V2.md`가 없다. 실제 구현을 시작하기
전에 이 문서의 결정이 현재 구현 계약에 반영됐는지 확인한다.


## 1. 최종 설계 결정

### 1.1 사용하는 hint

다음 세 hint를 사용한다.

```spectec
hint(maude_sort)
hint(maude_subsort "부모-syntax")
hint(maude_context)
```

의미는 다음과 같다.

```text
maude_sort             이 syntax를 독립 Maude sort로 생성
maude_subsort "T"      현재 syntax의 sort를 T의 subsort로 생성
maude_context          이 context rule을 일반 crl이 아닌 전용 focus 파이프라인으로 생성
```

`hint(maude_list)`와 `hint(maude_list_subsort)`는 만들지 않는다. 리스트 필요 여부는
IL의 `IterT`에서 자동으로 확인한다.

전용 리스트 필요 여부는 다음 두 정보를 합쳐 자동으로 결정한다.

```text
syntax T에 hint(maude_sort)가 있음
+
IL에 IterT(VarT(T), List 또는 List1)가 있음
=> T용 Prelude LIST 인스턴스 생성
```

subsort는 constructor 집합 포함관계로 추측하지 않는다. source hint에 적힌 edge만
생성한다. 이 결정은 translator를 작고 감사 가능하게 유지하고, `Val < Instr` 같은
의도하지 않은 관계의 생성을 막는다.

### 1.2 초기 critical syntax

초기 대상은 다음 다섯 개다.

```text
num, vec, ref, val, instr
```

다섯 syntax 모두 실제 Maude sort가 되므로 `hint(maude_sort)`를 붙인다. 하위
syntax에는 부모 관계도 명시한다.

```spectec
syntax num
  hint(maude_sort)
  hint(maude_subsort "val")
  hint(maude_subsort "instr")

syntax vec
  hint(maude_sort)
  hint(maude_subsort "val")
  hint(maude_subsort "instr")

syntax ref
  hint(maude_sort)
  hint(maude_subsort "val")
  hint(maude_subsort "instr")

syntax val
  hint(maude_sort)

syntax instr
  hint(maude_sort)
```

초기 scalar sort graph는 다음과 같다.

```text
          Val -------+
         /            |
Num/Vec/Ref           +----< SpectecTerminal
         \            |
          Instr ------+
```

생성할 Maude 관계는 다음과 같다.

```maude
subsorts Num Vec Ref < Val .
subsorts Num Vec Ref < Instr .
subsorts Val Instr < SpectecTerminal .
```

다음 관계는 생성하지 않는다.

```maude
subsort Val < Instr .
```

`num`, `vec`, `ref`가 두 부모를 갖는 것은 source hint로 명시된 의도다. 반면
`Val < Instr`는 source에 명시하지 않았으므로 생성하지 않는다.

### 1.3 리스트 관계

Prelude가 각 리스트 내부에서 다음 관계를 자동으로 제공한다.

```text
Val   < NeValList   < ValList
Instr < NeInstrList < InstrList
```

두 리스트 사이에는 아무 subsort 관계도 만들지 않는다.

```maude
--- 금지
subsort ValList < InstrList .
subsort NeValList < NeInstrList .
```

### 1.4 일반 리스트와 typed list

세 가지 Prelude LIST 인스턴스를 함께 사용한다.

```text
LIST{SpectecTerminalView}  일반적인 x*
LIST{VAL-VIEW}             val*
LIST{INSTR-VIEW}           instr*, instr_1*
```

일반 리스트는 한 번만 import하므로 Prelude 이름을 그대로 사용한다.

```text
List{SpectecTerminalView}
NeList{SpectecTerminalView}
nil
__
append
occurs
size
```

`Val`과 `Instr`는 `Num`, `Vec`, `Ref`를 공유한다. 따라서 두 typed LIST를 원래
이름 그대로 함께 import하면 `nil`, `__`, `size` 등에 preregularity 충돌이
발생한다. Typed LIST 두 개는 모든 공개/내부 연산자를 서로 다른 이름으로
rename한다.


## 2. 현재 방식과 목표 방식

### 2.1 현재 방식

`translator/backend/spectec-support/pretype.maude`는 리스트를 수동 정의한다.

```maude
sort SpectecTerminals .
subsort SpectecTerminal < SpectecTerminals .

op eps : -> SpectecTerminals [ctor] .
op __ : SpectecTerminals SpectecTerminals -> SpectecTerminals
  [ctor assoc id: eps] .
```

`translator/backend/spectec-support/sequence.maude`는 `len`, membership,
concatenation 및 여러 SpecTec sequence 연산을 수동 정의한다.

현재 OCaml 변환기는 모든 `IterT _`를 `SpectecTerminals`로 보낸다.

```ocaml
| IterT _ -> "SpectecTerminals"
```

### 2.2 목표 방식

```text
일반 x*    -> List{SpectecTerminalView}
val*       -> ValList
val+       -> NeValList
instr*     -> InstrList
instr+     -> NeInstrList
instr_1*   -> InstrList
```

```text
빈 일반 리스트  -> nil
빈 val 리스트   -> valNil
빈 instr 리스트 -> instrNil
```

```text
일반 리스트 연결  -> __ / append
val 리스트 연결   -> valConcat / valAppend
instr 리스트 연결 -> instrConcat / instrAppend
```


## 3. 최종 Maude 모듈 구조

모듈 의존 관계는 다음과 같다.

```text
DSL-TERM
  +-- SpectecTerminalView
  |     |
  |   DSL-PRETYPE
  |     |  protecting LIST{SpectecTerminalView}
  |     |
  |   SPECTEC-SUPPORT
  |
  +-- SPEC2MAUDE-SORTS
        |  Num/Vec/Ref/Val/Instr
        |
        +-- VAL-VIEW
        +-- INSTR-VIEW

SPEC2MAUDE-GENERATED
     protecting SPECTEC-SUPPORT
     protecting SPEC2MAUDE-SORTS
     protecting renamed LIST{VAL-VIEW}
     protecting renamed LIST{INSTR-VIEW}
     generated constructors/equations/rules
```

`DSL-TERM`, `DSL-PRETYPE`, `SPECTEC-SUPPORT`는 hand-written support다.
`SPEC2MAUDE-SORTS`, `VAL-VIEW`, `INSTR-VIEW`,
`SPEC2MAUDE-GENERATED`는 translator가 생성한다.


### 3.1 Hand-written `DSL-TERM`과 일반 list view

`translator/backend/spectec-support/pretype.maude`에 view를 추가한다.

```maude
fmod DSL-TERM is
  sort SpectecTerminal .
  sort SpectecType .
  sort SpectecDef .
endfm

view SpectecTerminalView from TRIV to DSL-TERM is
  sort Elt to SpectecTerminal .
endv
```


### 3.2 Hand-written `DSL-PRETYPE`

일반 리스트는 rename하지 않고 Prelude 이름을 그대로 사용한다.

```maude
fmod DSL-PRETYPE is
  protecting DSL-TERM .
  protecting BOOL .
  protecting NAT .
  protecting INT .
  protecting RAT .
  protecting FLOAT .
  protecting STRING .

  protecting LIST{SpectecTerminalView} .

  --- bool/rat/float/text, seq/unseq, typecheck 등 기존의 비-list 정의
endfm
```

다음 수동 정의는 삭제한다.

```maude
sort SpectecTerminals .
subsort SpectecTerminal < SpectecTerminals .
op eps : -> SpectecTerminals [ctor] .
op __ : SpectecTerminals SpectecTerminals -> SpectecTerminals
  [ctor assoc id: eps] .
```

삭제 후 사용하는 Prelude 이름은 다음과 같다.

```text
SpectecTerminals -> List{SpectecTerminalView}
eps              -> nil
__               -> __
len              -> size
_++_             -> append
_<-_             -> occurs
```


### 3.3 Generated `SPEC2MAUDE-SORTS`

`hint(maude_sort)`와 명시적인 `hint(maude_subsort "...")` edge를 이용해
`output.maude` 앞부분에 생성한다. Constructor 포함관계로 subsort를 추론하지 않는다.

```maude
fmod SPEC2MAUDE-SORTS is
  protecting DSL-TERM .

  sorts Num Vec Ref Val Instr .

  subsorts Num Vec Ref < Val .
  subsorts Num Vec Ref < Instr .

  subsorts Val Instr < SpectecTerminal .
endfm
```

이 모듈은 fixed `DSL-TERM`을 대체하지 않는다. 입력 SpecTec과 hint에 따라 달라지는
generated scalar sort를 `DSL-TERM` 위에 추가한다. 여기서 `SPECTEC-SUPPORT` 전체를
protecting하면 안 된다. `SPECTEC-SUPPORT`가 가진 일반 Prelude LIST가 typed view
인스턴스를 통해 반복 import되어 duplicate-import advisory와 preregularity 문제가
발생하기 때문이다.


### 3.4 Generated views

Maude view의 target sort는 view보다 먼저 선언되어야 한다. 따라서
`SPEC2MAUDE-SORTS` 뒤에 views를 생성한다.

```maude
view VAL-VIEW from TRIV to SPEC2MAUDE-SORTS is
  sort Elt to Val .
endv

view INSTR-VIEW from TRIV to SPEC2MAUDE-SORTS is
  sort Elt to Instr .
endv
```

`ValListView`나 `InstrListView`는 만들지 않는다. View가 연결하는 것은 리스트가
아니라 리스트의 원소 sort인 `Val`, `Instr`다.


### 3.5 Generated typed LIST imports

```maude
mod SPEC2MAUDE-GENERATED is
  protecting SPECTEC-SUPPORT .
  protecting SPEC2MAUDE-SORTS .

  protecting LIST{VAL-VIEW} * (
    sort List{VAL-VIEW} to ValList,
    sort NeList{VAL-VIEW} to NeValList,

    op nil to valNil,
    op __ to valConcat,
    op append to valAppend,
    op head to valHead,
    op tail to valTail,
    op last to valLast,
    op front to valFront,
    op occurs to valOccurs,
    op reverse to valReverse,
    op $reverse to valReverseAux,
    op size to valSize,
    op $size to valSizeAux
  ) .

  protecting LIST{INSTR-VIEW} * (
    sort List{INSTR-VIEW} to InstrList,
    sort NeList{INSTR-VIEW} to NeInstrList,

    op nil to instrNil,
    op __ to instrConcat,
    op append to instrAppend,
    op head to instrHead,
    op tail to instrTail,
    op last to instrLast,
    op front to instrFront,
    op occurs to instrOccurs,
    op reverse to instrReverse,
    op $reverse to instrReverseAux,
    op size to instrSize,
    op $size to instrSizeAux
  ) .

  --- 나머지 generated constructor/equation/rule
endm
```

`sort List{VAL-VIEW} to ValList`는 의미를 바꾸는 coercion이 아니다. Prelude가
생성한 긴 sort 이름에 짧은 generated 이름을 붙이는 module renaming이다.


## 4. SpecTec hint 수정

### 4.1 `val` 계열

대상 파일:

```text
spectec/wasm-3.0/4.0-execution.configurations.spectec
```

```spectec
syntax num
  hint(desc "number value")
  hint(maude_sort)
  hint(maude_subsort "val")
  hint(maude_subsort "instr") =
  | CONST numtype num_(numtype)

syntax vec
  hint(desc "vector value")
  hint(maude_sort)
  hint(maude_subsort "val")
  hint(maude_subsort "instr") =
  | VCONST vectype vec_(vectype)

syntax ref hint(desc "reference value") hint(macro "reff")
  hint(maude_sort)
  hint(maude_subsort "val")
  hint(maude_subsort "instr") =
  ...

syntax val hint(desc "value") hint(maude_sort) =
  | num | vec | ref
```

### 4.2 `instr`

대상 파일:

```text
spectec/wasm-3.0/1.3-syntax.instructions.spectec
```

```spectec
syntax instr hint(desc "instruction") hint(maude_sort)
```

### 4.3 `Step/ctxt-instrs`

대상 파일:

```text
spectec/wasm-3.0/4.3-execution.instructions.spectec
```

```spectec
rule Step/ctxt-instrs:
  z; val* instr* instr_1*  ~>  z'; val* instr'* instr_1*
  -- Step: z; instr* ~> z'; instr'*
  -- if val* =/= eps \/ instr_1* =/= eps
  hint(maude_context)
```

이 hint는 rule 이름을 hard-code하기 위한 표시가 아니다. `RuleH`에 붙은
`maude_context`를 보고 해당 rule의 LHS, RHS, recursive `RulePr`, 조건을 분석해
전용 focus 파이프라인으로 lowering하라는 명시적 요청이다.


## 5. `IterT` 정적분석

### 5.1 `TypD`와 `IterT`

`syntax val = ...` 정의 자체는 IL의 `TypD("val", ...)`다.

다른 위치에서 사용되는 `val*`는 IL type으로 다음과 같이 나타난다.

```ocaml
IterT (VarT ("val", []), List)
```

매핑은 다음과 같다.

```text
val      VarT("val", [])
val*     IterT(VarT("val", []), List)
val+     IterT(VarT("val", []), List1)
val?     IterT(VarT("val", []), Opt)
val^N    IterT(VarT("val", []), ListN(...))
```

IL의 `List`는 Maude LIST가 아니다. SpecTec source에서 `*`가 붙었다는 AST
표시다. Translator가 이 표시를 Prelude `LIST{View}`로 lowering한다.


### 5.2 수집 알고리즘

Prescan은 두 집합과 subsort edge 집합을 만든다.

```ocaml
maude_sort_types : StringSet.t
maude_subsort_edges : (string * string) list
required_lists   : StringSet.t
```

첫 번째 순회에서 `TypH`를 읽는다.

```text
HintD(TypH("val",   [maude_sort])) -> maude_sort_types에 val 추가
HintD(TypH("instr", [maude_sort])) -> maude_sort_types에 instr 추가

HintD(TypH("num", [maude_subsort "val"]))
  -> maude_subsort_edges에 (num, val) 추가

HintD(TypH("num", [maude_subsort "instr"]))
  -> maude_subsort_edges에 (num, instr) 추가
```

`maude_subsort`의 child와 parent는 모두 `maude_sort_types`에 있어야 한다. 자기 자신을
부모로 지정한 edge, 중복 edge, 순환 graph, 존재하지 않는 parent는 명시적 진단으로
거부한다. Constructor 집합의 포함관계를 계산해서 edge를 추가하지 않는다.

두 번째 순회에서 모든 IL `typ`을 재귀적으로 방문한다.

```ocaml
let rec collect_required_list maude_sorts required typ =
  match typ.it with
  | IterT ({it = VarT (id, []); _}, (List | List1)) ->
      if StringSet.mem id.it maude_sorts then
        StringSet.add id.it required
      else
        required

  | IterT (element, _) ->
      collect_required_list maude_sorts required element

  | TupT fields ->
      List.fold_left
        (fun required (_, field_typ) ->
          collect_required_list maude_sorts required field_typ)
        required fields

  | VarT _ | BoolT | NumT _ | TextT ->
      required
```

방문 범위에는 다음 type 위치가 모두 포함되어야 한다.

- `TypD`의 alias, struct field, variant case payload
- `RelD`의 relation type
- `DecD`의 parameter/result type
- quantifier와 premise에 포함된 type
- expression note에 기록된 type을 실제 representation 결정에 사용할 때

동일한 syntax가 여러 번 나타나도 LIST 인스턴스는 한 번만 생성한다.

```text
instr* + instr_1* + expr = instr*
=> required_lists에는 instr 하나만 등록
=> LIST{INSTR-VIEW} 한 번만 생성
```

초기 단계에서는 `List`와 `List1`만 typed LIST 대상으로 한다. `Opt`와 `ListN`은
현재 표현을 유지한다. 이를 임의로 `TList`로 보내지 않는다.


## 6. Translator 수정 단계

### Step 1. 기준선 저장

수정 전 다음을 실행하고 결과를 보관한다.

```sh
dune build
dune exec bin/spec2maude.exe -- -o /tmp/spec2maude-maudesort-before.maude
maude -no-banner translator/backend/semantics.maude
```

확인할 내용:

- 생성된 `output.maude`의 줄 수와 hash
- `Step/ctxt-instrs` 관련 rule 위치
- 대표 timeout 입력의 실행시간과 rewrite 수
- 현재 Maude load diagnostics


### Step 2. 일반 리스트를 Prelude로 교체

수정 파일:

```text
translator/backend/spectec-support/pretype.maude
translator/backend/spectec-support/sequence.maude
translator/backend/spectec-support/option.maude
translator/backend/spectec-support/tuple.maude
translator/backend/spectec-support/record.maude
translator/backend/builtins.maude
translator/backend/relation-backends.maude
translator/prescan.ml
translator/term.ml
translator/iter.ml
translator/prem.ml
translator/decd.ml
```

핵심 변경:

```text
SpectecTerminals -> List{SpectecTerminalView}
eps              -> nil
len              -> size
TS ++ WTS        -> append(TS, WTS)
K <- TS          -> occurs(K, TS)
```

일반 리스트의 `__`는 Prelude가 같은 이름으로 제공하므로 기존 whitespace sequence
출력을 유지할 수 있다.

#### Prelude로 완전히 대체할 기능

```text
수동 빈 리스트/concat sort  -> nil, __
len                          -> size
_++_                         -> append
_<-_                         -> occurs
head/tail/last/front         -> Prelude 구현
reverse                      -> Prelude 구현
```

#### Prelude에 없는 SpecTec 전용 기능

다음 기능은 Maude Prelude `LIST`에 존재하지 않는다.

```text
indexDefined, index
take, drop, slice
setAt, splice
lift, repeatSeq
SpecTec typecheck/coercion helpers
```

이 함수들을 삭제하면 현재 generated semantics가 load 또는 실행되지 않는다. 이들은
Prelude의 `List{SpectecTerminalView}`, `nil`, `__`, `size`, `append` 위에서 동작하도록
수정해서 유지한다. Prelude 기본 리스트를 다시 구현하는 코드와 SpecTec에만 필요한
sequence 연산을 구분한다.

예:

```maude
op indexDefined : List{SpectecTerminalView} Nat -> Bool .
op index : List{SpectecTerminalView} Nat ~> SpectecTerminal .

eq indexDefined(TS, N) = N < size(TS) .

op slice : List{SpectecTerminalView} Nat Nat
  -> List{SpectecTerminalView} .
```

완료 조건:

- hand-written `sort SpectecTerminals`, `eps`, generic `__`가 없음
- 일반 리스트 API가 Prelude 이름을 사용함
- `dune build` 성공
- 기존 generated semantics가 Maude에서 load됨


### Step 3. `maude_sort`와 `maude_subsort` hint를 읽는다

수정 파일:

```text
translator/prescan.ml
```

필요한 기능:

1. `TypH`에서 flag hint `maude_sort`를 수집한다.
2. `TypH`에서 string payload를 갖는 `maude_subsort`를 수집한다.
3. `maude_sort`의 payload가 `El.Ast.SeqE []`인지 검증한다.
4. `maude_subsort`의 payload가 syntax 이름 하나인지 검증한다.
5. child/parent 존재 여부, 중복, 자기 edge, 순환을 검증한다.
6. `maude_sort_types`와 `maude_subsort_edges` accessor를 제공한다.

`maude_sort`/`maude_subsort`가 없는 syntax 이름을 코드에서 `val`, `instr`, `num`
문자열로 hard-code하지 않는다. Translator는 annotation에 적힌 graph만 생성한다.

완료 조건:

- `num`, `vec`, `ref`, `val`, `instr`의 `maude_sort`가 IL `TypH`에서 발견됨
- `(num|vec|ref, val|instr)` 여섯 edge가 발견됨
- `Val < Instr` edge가 없음
- hint를 제거하면 해당 sort/edge/list 요청도 사라짐
- 잘못된 hint payload는 명시적 오류가 됨


### Step 4. IL에서 필요한 LIST 인스턴스를 수집한다

수정 파일:

```text
translator/prescan.ml
```

`IterT(VarT(T), List/List1)`를 재귀적으로 찾아 `T`가 `maude_sort_types`에 있을 때만
`required_lists`에 추가한다.

필요한 metadata 예:

```ocaml
type typed_list =
  { source_type : string
  ; element_sort : string
  ; list_sort : string
  ; nonempty_sort : string
  ; view_name : string
  ; nil_name : string
  ; concat_name : string
  }
```

이름은 source type과 기존 name allocator에서 기계적으로 파생한다.

```text
val   -> Val, ValList, NeValList, VAL-VIEW, valNil, valConcat
instr -> Instr, InstrList, NeInstrList, INSTR-VIEW, instrNil, instrConcat
```

완료 조건:

- `required_lists`가 `val`, `instr`를 포함함
- 변수 이름 `instr_1`을 검사하는 코드가 없음
- 같은 element syntax용 view/LIST가 중복 생성되지 않음


### Step 5. Generated sort module과 views를 출력한다

수정 파일:

```text
bin/spec2maude.ml
translator/definition.ml
translator/maude/maude_il.ml
translator/maude/maude_emit.ml
```

현재 `bin/spec2maude.ml`은 `SPEC2MAUDE-GENERATED` 하나만 출력한다. 출력 순서를
다음처럼 확장한다.

```text
1. SPEC2MAUDE-SORTS functional module
2. VAL-VIEW / INSTR-VIEW
3. SPEC2MAUDE-GENERATED system module
```

Maude IL에 필요한 표현이 없다면 raw string을 곳곳에서 조립하지 말고 다음 개념을
작게 추가한다.

```text
View declaration
Parameterized module import
Sort renaming
Operator renaming
```

기존 recursive AST lowering은 그대로 유지하고 output unit 조립만 분리한다.

완료 조건:

- target sort가 view보다 먼저 선언됨
- views가 final module보다 먼저 선언됨
- typed LIST의 모든 중복 operator가 rename됨
- `Val < Instr`, `ValList < InstrList`가 없음


### Step 6. `IterT` representation sort를 변경한다

수정 파일:

```text
translator/prescan.ml
translator/term.ml
translator/iter.ml
translator/prem.ml
translator/decd.ml
```

representation 규칙:

```text
IterT(VarT(T), List)  + required LIST -> TList
IterT(VarT(T), List1) + required LIST -> NeTList
다른 IterT                            -> List{SpectecTerminalView}
```

초기 기대 결과:

```text
IterT(val, List)    -> ValList
IterT(val, List1)   -> NeValList
IterT(instr, List)  -> InstrList
IterT(instr, List1) -> NeInstrList
```

현재 여러 모듈에 hard-coded된 `SpectecTerminals`를 단순 문자열 치환하지 않는다.
각 변수와 helper가 어떤 IL `typ`에서 유래했는지 따라 representation sort를 요청하게
한다. 원래 type을 복구할 수 없는 generated helper는 metadata에 source type을
명시적으로 저장한다.

완료 조건:

- `val*` 변수는 `ValList`
- `instr*`, `instr_1*` 변수는 `InstrList`
- 다른 리스트는 `List{SpectecTerminalView}`
- 변수 이름에 따른 dispatch가 없음


### Step 7. 리스트 term과 연산을 type-directed로 출력한다

현재 `Term.sequence`는 모든 리스트에 `eps`와 generic whitespace `__`를 사용한다.
다음 세 representation을 구분한다.

```text
Generic:
  []      -> nil
  [x]     -> x
  [x,y]   -> x y

Val:
  []      -> valNil
  [x]     -> x
  [x,y]   -> valConcat(x, y)

Instr:
  []      -> instrNil
  [x]     -> x
  [x,y]   -> instrConcat(x, y)
```

예시 helper:

```ocaml
type list_representation =
  | GenericList
  | TypedList of typed_list

let rec sequence representation terms =
  match representation, terms with
  | GenericList, [] -> Const "nil"
  | GenericList, [term] -> term
  | GenericList, term :: terms ->
      App ("_ _", [term; sequence GenericList terms])

  | TypedList info, [] -> Const info.nil_name
  | TypedList _, [term] -> term
  | TypedList info, term :: terms ->
      App
        (info.concat_name,
         [term; sequence (TypedList info) terms])
```

`ListE`, `CatE`, `LenE`, `MemE`, `IdxE`, `SliceE`, update/extension lowering은
operand/result IL type을 보고 다음 연산자를 선택한다.

```text
Generic  size / append / occurs
Val      valSize / valAppend / valOccurs
Instr    instrSize / instrAppend / instrOccurs
```

Prelude에 없는 typed `index/slice/splice`가 실제 IL 사용 지점에서 필요하면 다음 중
하나를 구현 전에 명시적으로 선택하고 Maude load test를 추가한다.

1. `LIST{X}`를 protecting하는 작은 parameterized `SPECTEC-SEQUENCE{X :: TRIV}`에서
   필요한 SpecTec 연산을 한 번 정의하고 세 view에 instantiate한다.
2. 필요한 typed overload만 generator가 생성한다.

같은 재귀 함수를 Val/Instr용으로 복사하는 방식은 사용하지 않는다. 권장안은 1번이다.


### Step 8. 전체 검증

빌드 및 생성:

```sh
dune build
dune exec bin/spec2maude.exe -- -o /tmp/spec2maude-maudesort-after.maude
```

생성물 정적 확인:

```sh
rg -n 'fmod SPEC2MAUDE-SORTS|view VAL-VIEW|view INSTR-VIEW' \
  /tmp/spec2maude-maudesort-after.maude

rg -n 'ValList|NeValList|InstrList|NeInstrList' \
  /tmp/spec2maude-maudesort-after.maude

rg -n 'Val < Instr|ValList < InstrList|NeValList < NeInstrList' \
  /tmp/spec2maude-maudesort-after.maude
```

마지막 명령은 결과가 없어야 한다.

Maude load:

```sh
dune exec bin/spec2maude.exe --
maude -no-banner translator/backend/semantics.maude
```

필수 Maude smoke reductions:

```text
일반 nil/__/size/append/occurs
valNil/valConcat/valSize/valHead
instrNil/instrConcat/instrSize/instrHead
Num 원소가 ValList와 InstrList 각각에서 정상 사용되는지
ValList가 InstrList로 암시적 coercion되지 않는지
```

회귀 검증:

- `wat_examples/` generation
- generated `output.maude` load
- 대표 relation 실행
- 기존 generic sequence의 index/slice/update smoke
- official suite의 짧은 표본 실행


## 7. 구현 완료 조건

다음을 모두 만족해야 sort/list 단계가 완료된다.

- `num`, `vec`, `ref`, `val`, `instr`에 `hint(maude_sort)`가 있다.
- `num`, `vec`, `ref`에 `hint(maude_subsort "val")`과
  `hint(maude_subsort "instr")`가 있다.
- `hint(maude_list)`와 `hint(maude_list_subsort)`가 없다.
- 일반 리스트가 raw `LIST{SpectecTerminalView}`를 사용한다.
- `SpectecTerminals`와 `eps`가 public representation으로 남아 있지 않다.
- Prelude에 있는 `size`, `append`, `occurs`, `head`, `tail`, `last`, `front`,
  `reverse`를 다시 구현하지 않는다.
- Prelude에 없는 SpecTec sequence 기능만 Prelude list 위에 유지한다.
- `SPEC2MAUDE-SORTS`와 필요한 views가 translator에서 생성된다.
- `val*`는 `ValList`, `instr*`와 `instr_1*`는 `InstrList`를 사용한다.
- Typed LIST의 중복 연산자는 모두 rename된다.
- `Val < Instr`, `ValList < InstrList`, `NeValList < NeInstrList`가 없다.
- `dune build`와 Maude load가 성공한다.
- 기존 example과 generic sequence smoke가 통과한다.


## 8. `Step/ctxt-instrs` 최적화의 의미

### 8.1 typed list만으로 끝나지 않는 이유

Source rule은 다음과 같다.

```spectec
rule Step/ctxt-instrs:
  z; val* instr* instr_1*  ~>  z'; val* instr'* instr_1*
  -- Step: z; instr* ~> z'; instr'*
  -- if val* =/= eps \/ instr_1* =/= eps
  hint(maude_context)
```

`ValList`와 `InstrList`를 분리하면 `val*`와 instruction list의 경계는 명확해진다.
그러나 `instr* instr_1*`는 둘 다 `InstrList`이므로 Maude가 focus의 끝 경계를 여러
방식으로 시험하는 문제는 남는다. 따라서 translator가 prefix/focus/suffix 탐색을
명시적으로 생성해야 한다.

```text
입력 instruction list
  -> PREFIX : ValList
  -> FOCUS  : InstrList
  -> SUFFIX : InstrList
```

### 8.2 보존할 의미: raw SpecTec one-step relation

이 계획은 공식 interpreter의 leftmost 실행 알고리즘 하나만 구현하는 것이 아니라,
SpecTec source relation이 허용하는 모든 one-step successor를 보존한다.

예를 들어 `Z ; v TRAP NOP`에서는 서로 다른 focus가 가능하다.

```text
PREFIX = 없음  | FOCUS = v TRAP   | SUFFIX = NOP
PREFIX = v     | FOCUS = TRAP NOP | SUFFIX = 없음
```

전체 term에 direct trap rule을 적용하는 경로까지 포함하면 raw relation에는 다음
one-step successor가 존재할 수 있다.

```text
Z ; TRAP
Z ; TRAP NOP
Z ; v TRAP
```

이 상태들이 나중에 같은 결과로 합쳐지더라도 모델체커가 보는 한 단계 상태 graph는
서로 다르다. 따라서 focus 하나를 `eq`로 고정해서 반환하지 않는다.

```text
enabled 검사       eq / ceq
focus 후보 열거    rl / crl
heating             crl
direct 실행         rl / crl
cooling             eq
public context Step atomic crl
```


## 9. Context rule과 direct rule 분류

### 9.1 `maude_context` 처리

Prescan은 `RuleH`에서 `hint(maude_context)`를 수집한다. 이 hint가 붙은 source
`RuleD`는 기존의 일반적인 `crl`로도 동시에 출력하지 않는다. 대신 10절부터 13절의
전용 파이프라인으로 한 번만 출력한다.

Rule 이름 `Step/ctxt-instrs`를 문자열 비교해서 동작을 결정하지 않는다. 다음 정보는
IL AST에서 읽는다.

```text
context rule의 LHS/RHS
recursive RulePr의 target relation과 input/output
prefix/focus/suffix에 해당하는 IterT
원래 IfPr/LetPr/RulePr 조건
```

source shape가 현재 지원하는 context schema와 맞지 않으면 추측해서 생성하지 않고
명시적 `Unsupported` 진단을 낸다.

### 9.2 direct 후보

Context rule의 recursive premise가 호출하는 relation을 기준으로 direct 후보를
수집한다. 같은 relation을 더 작은 subterm에 다시 호출하는 context rule은 후보에서
제외한다. `Step/pure`처럼 다른 execution relation에 위임하는 non-context rule은
그 위임 구조를 AST에서 따라가되 instruction 이름이나 rule 이름을 hard-code하지
않는다.

```text
direct 후보       현재 focus에 실제 의미 전이를 적용할 수 있음
context 후보      다시 focus 탐색을 시작하므로 제외
```

현재 translator가 생성하는 relation별 enabledness helper를 재사용할 수 있는지 먼저
확인한다. 재사용하려면 context rule helper가 aggregate에 포함되지 않아야 하고, helper가
source rule의 전체 LHS와 원래 equational condition을 보존해야 한다.


## 10. Direct rule별 enabled 검사

아래 코드는 설계를 설명하기 위한 schema다. 실제 sort 이름, typed-list constructor,
condition 문법은 generated Maude를 Maude 3.5.1로 load하며 확정한다.

```maude
--- Direct rule마다 생성
op enable-add : Config -> Bool .

eq enable-add(Z ; V1 V2 ADD) = true .
eq enable-add(C) = false [owise] .

--- 원래 equational side condition이 있다면 ceq
op enable-forever : Config -> Bool .

ceq enable-forever(Z ; FOREVER-LHS) = true
  if FOREVER-EQUATIONAL-CONDITIONS .
eq enable-forever(C) = false [owise] .

--- direct helper들을 하나로 합침
op enable : Config -> Bool [frozen (1)] .

ceq enable(C) = true if enable-add(C) == true .
ceq enable(C) = true if enable-forever(C) == true .
ceq enable(C) = true if enable-nop(C) == true .
ceq enable(C) = true if enable-trap(C) == true .
eq enable(C) = false [owise] .
```

`enable`은 실행 결과를 계산하지 않는다. 현재 `Config`가 어떤 direct rule의 LHS와
원래 조건을 만족하는지만 검사한다.

Maude `ceq`에는 rewrite condition을 그대로 넣을 수 없다. Source direct rule의
enabledness가 `RulePr` 실행 결과에 의존한다면 이를 equational condition으로 바꾸어
쓰지 않는다. 구현 전 해당 case를 다음 중 하나로 명시적으로 분류한다.

1. 이미 생성된 equational enabledness helper로 증명 가능
2. 별도의 relational enabled-search가 필요
3. 현재 단계에서는 `Unsupported`


## 11. 모든 focus 후보 열거

### 11.1 선언 위치

Maude 공식 `prelude.maude`에는 `LIST{X :: TRIV}`만 의존한다. 다음 focus 선언과
rule은 공식 Prelude를 수정하지 않고, typed list와 `Config`가 보이는 generated support
부분에 한 번 생성한다.

```maude
sorts FocusSearch FocusTarget .
subsort FocusTarget < FocusSearch .

op focus : Config -> FocusSearch [frozen (1)] .
op scanStart : State ValList InstrList -> FocusSearch [ctor] .
op scanEnd : State ValList InstrList InstrList -> FocusSearch [ctor] .
op target : ValList Config InstrList -> FocusTarget [ctor] .
```

### 11.2 탐색 rule

가독성을 위해 아래에서는 리스트 연결을 공백으로 썼다. 실제 생성물은 3.5절에서
rename한 `valConcat`과 `instrConcat`을 type-directed로 사용한다.

```maude
rl [focus-init] :
  focus(Z ; ALL)
  =>
  scanStart(Z, valNil, ALL) .

--- 현재 위치에서 후보를 시작하는 branch
rl [focus-start-here] :
  scanStart(Z, PREFIX, INSTR REST)
  =>
  scanEnd(Z, PREFIX, INSTR, REST) .

--- 현재 원소가 value이면 다음 위치도 시작점으로 시험하는 branch
crl [focus-skip-one-value] :
  scanStart(Z, PREFIX, VALUE REST)
  =>
  scanStart(Z, PREFIX VALUE, REST)
  if VALUE : Val .

--- 현재 후보의 끝을 오른쪽으로 한 칸 확장
rl [focus-extend-one] :
  scanEnd(Z, PREFIX, FOCUS, INSTR SUFFIX)
  =>
  scanEnd(Z, PREFIX, FOCUS INSTR, SUFFIX) .

--- direct rule이 실행 가능하면 후보 확정
crl [focus-found] :
  scanEnd(Z, PREFIX, FOCUS, SUFFIX)
  =>
  target(PREFIX, Z ; FOCUS, SUFFIX)
  if enable(Z ; FOCUS) == true
  /\ (PREFIX =/= valNil \/ SUFFIX =/= instrNil) .
```

두 branch의 역할은 다음과 같다.

```text
focus-skip-one-value  focus 시작점을 오른쪽으로 이동
focus-extend-one      focus 끝점을 오른쪽으로 이동
```

Prefix는 `val*`여야 하므로 value만 prefix로 넘긴다. Non-value instruction을 만난 뒤에는
그 instruction을 건너뛰어 새로운 시작점을 만들지 않는다.

### 11.3 간단한 실행 예

```text
입력: 0 1 2 ADD NOP

시작점 0
0
0 1
0 1 2
0 1 2 ADD
0 1 2 ADD NOP
-> 전부 enable = false

0을 PREFIX로 이동

시작점 1
1
1 2
1 2 ADD
-> enable = true

결과
PREFIX = 0
FOCUS  = 1 2 ADD
SUFFIX = NOP
```


## 12. Heating, direct-only 실행, cooling

### 12.1 Heating

```maude
sorts Hole HeatSearch Heated .
subsort Heated < HeatSearch .

op hole : ValList InstrList -> Hole [ctor] .
op heat : Config -> HeatSearch [frozen (1)] .
op _~>_ : Config Hole -> Heated [ctor frozen (2)] .

crl [heating-ctxt-instrs] :
  heat(Z ; ALL)
  =>
  (Z ; FOCUS) ~> hole(PREFIX, SUFFIX)
  if focus(Z ; ALL)
       => target(PREFIX, Z ; FOCUS, SUFFIX) .
```

Heating은 focus를 실행하지 않는다. 전체 instruction list에서 focus를 떼어내고 나중에
복원할 prefix/suffix를 `hole`에 저장한다.

### 12.2 `fire-direct`

기존 public direct rule은 그대로 유지한다. 같은 source `RuleD`에서 context 내부
실행 전용 private rule을 추가 생성한다.

```maude
sorts DirectSearch DirectResult .
subsort DirectResult < DirectSearch .

op fire-direct : Config -> DirectSearch [frozen (1)] .
op direct-result : Config -> DirectResult [ctor] .

rl [fire-step-add] :
  fire-direct(Z ; V1 V2 ADD)
  =>
  direct-result(Z ; ADD-RESULT) .

crl [fire-step-forever] :
  fire-direct(Z ; FOREVER-LHS)
  =>
  direct-result(Z2 ; FOREVER-RESULT)
  if FOREVER-ORIGINAL-CONDITIONS .
```

`fire-direct`도 direct rule들 사이의 pattern 검사는 수행한다. 이 helper의 목적은 direct
dispatch 자체를 없애는 것이 아니라, focus를 찾은 뒤 public `Step`을 다시 호출해서
`Step/ctxt-instrs`, `Step/ctxt-label`, `Step/ctxt-handler`, `Step/ctxt-frame` 같은 context
rule까지 재검사하고 focus 탐색을 반복하는 것을 막는 것이다.

### 12.3 Cooling

`ValList < InstrList`를 만들지 않는다. 따라서 저장된 value prefix를 instruction list에
돌려놓을 때는 명시적인 구조 변환을 사용한다.

```maude
op vals-to-instrs : ValList -> InstrList .
op cool : Hole Config -> Config .

eq vals-to-instrs(valNil) = instrNil .

--- 아래 재귀 equation은 Num/Vec/Ref처럼 Val과 Instr의 공통 explicit child sort에서 생성
eq vals-to-instrs(valConcat(VALUE, VALUES))
  = instrConcat(VALUE, vals-to-instrs(VALUES)) .

eq cool(hole(PREFIX, SUFFIX), Z2 ; RESULT)
  = Z2 ;
      instrConcat(
        vals-to-instrs(PREFIX),
        instrConcat(RESULT, SUFFIX)) .
```

실제 equation은 `VALUE : Val` 변수를 곧바로 `Instr` 자리에 넣지 않는다. Translator는
`Val`과 `Instr`의 공통 explicit child sort인 `Num`, `Vec`, `Ref`에 맞는 구조적 case를
생성한다. 이것은 `Val < Instr` 또는 `ValList < InstrList`를 추가하는 우회가 아니다.


## 13. 최종 public `Step`은 atomic `crl` 하나

```maude
crl [step-ctxt-instrs] :
  step(Z ; ALL)
  =>
  cool(HOLE, RESULT-CONFIG)
  if heat(Z ; ALL)
       => FOCUS-CONFIG ~> HOLE
  /\ fire-direct(FOCUS-CONFIG)
       => direct-result(RESULT-CONFIG) .
```

실행 순서는 다음과 같다.

```text
enable로 가능한 focus 판정
-> focus rule로 모든 허용 후보 생성
-> heat로 PREFIX/FOCUS/SUFFIX 분리
-> fire-direct로 선택된 FOCUS 한 단계 실행
-> cool로 결과 재조립
-> public Step의 한 successor로 반환
```

`heat`, `focus`, `fire-direct`의 rewrite는 outer `crl`의 조건 안에서 수행한다. 따라서
모델체커가 관찰하는 public 상태 graph에는 `scanStart`, `scanEnd`, `heated` 같은 내부
상태를 별도의 Wasm 상태로 노출하지 않고, 원래 configuration에서 최종 configuration으로
가는 한 번의 `Step`만 보인다.


## 14. Translator 구현 단계: context 최적화

### Step 9. `maude_context` 수집과 schema 검증

수정 책임:

```text
translator/prescan.ml
translator/reld.ml
```

- `RuleH`의 `maude_context`를 수집한다.
- annotated `RuleD`의 recursive `RulePr`와 list iteration 구조를 분석한다.
- 현재 지원하는 prefix/focus/suffix schema인지 검증한다.
- rule 이름이나 variable 이름으로 dispatch하지 않는다.
- 지원하지 않는 shape는 `Unsupported`로 종료한다.

### Step 10. direct 후보와 enabled metadata 수집

- Context rule을 direct 후보에서 제외한다.
- 기존 relation enabled helper 생성 경로의 재사용 가능성을 확인한다.
- 각 helper가 전체 LHS pattern과 원래 equational condition을 보존하게 한다.
- Rewrite-dependent enabledness는 `ceq`로 잘못 변환하지 않는다.

### Step 11. focus/heat/hole/cool support 생성

- Typed list metadata에서 sort와 constructor 이름을 가져온다.
- `ValList < InstrList` 없이 `vals-to-instrs`를 생성한다.
- Helper 선언은 공식 Prelude가 아니라 generated support에 한 번만 출력한다.
- 여러 context hint가 생기면 name allocator로 충돌 없는 이름을 만든다.

### Step 12. `fire-direct`와 atomic context rule 생성

- 기존 public direct rule은 그대로 출력한다.
- 같은 lowered source body를 이용해 private `fire-direct` rule을 추가한다.
- annotated context rule의 기존 일반 `crl`은 출력하지 않는다.
- 마지막에는 outer atomic `crl` 하나를 출력한다.

### Step 13. Maude syntax와 의미 검증

문서의 코드는 설명용 schema이므로 다음을 실제 generated sort와 연산자에 맞춘 뒤
Maude 3.5.1로 load한다.

```text
_~>_ spelling과 frozen 위치
rl/crl label, eq/ceq 무label 정책
typed-list module renaming
valConcat/instrConcat의 실제 arity와 parsing
membership/equality/boolean condition 문법
rewrite condition의 sort 연결
모든 statement의 마침표
```


## 15. 최종 검증과 완료 조건

### 15.1 정적 검증

- `Num Vec Ref < Val`과 `Num Vec Ref < Instr`만 생성됨
- `Val < Instr`, `ValList < InstrList`, `NeValList < NeInstrList`가 없음
- 일반 `x*`는 `List{SpectecTerminalView}` 사용
- `val*`는 `ValList`, `instr*`/`instr_1*`는 `InstrList` 사용
- annotated context rule의 기존 associative baseline `crl`이 중복 출력되지 않음
- context helper가 `enable`/`fire-direct` 후보에 포함되지 않음

### 15.2 Maude smoke

```text
Prelude generic list 연산
ValList/InstrList 생성과 기본 연산
0 1 2 ADD NOP의 PREFIX/FOCUS/SUFFIX 탐색
v TRAP NOP의 모든 raw one-step successor
nested LABEL/HANDLER/FRAME context
rewrite-dependent direct condition
```

### 15.3 성능 검증

같은 machine, 같은 generated semantics, 같은 suite 입력으로 before/after를 비교한다.

```text
wall-clock time
Maude rewrite count
timeout 파일 수
one-step successor set
최종 결과 또는 property 결과
```

Typed list load 성공만으로 timeout 해결을 주장하지 않는다. Official suite 실행과
successor-set 회귀를 모두 통과해야 이 계획을 완료로 표시한다.
