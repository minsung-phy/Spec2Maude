# Maude syntax inventory audit

이 문서는 `output.maude`의 현재 syntax encoding을 전체적으로 훑은
inventory 보고서다. 목적은 다음 미팅 체크리스트 중 아직 남은 항목을
채우는 것이다.

- 어떤 sort가 있는지
- subsort 관계가 뭔지
- 어떤 term/operator가 어떤 sort를 갖는지
- 현재 정의가 실제 Wasm configuration에 절대 안 나오는 garbage term을 만드는지

이 문서는 대표 예시만 설명하는 문서가 아니라, 생성된 `output.maude` 전체를
기준으로 정리한 감사 결과다.

## 1. 결론

현재 `output.maude`는 old JHS 방식의 syntax membership layer를 더 이상
쓰지 않는다.

확인 결과:

- `SpectecType` 없음
- `SpectecCategory` 없음
- `WasmType` 없음
- `typecheck` 없음
- `hasType`, `WellTyped`, `_hasType_` 없음
- `SortCTOR...` singleton sort 없음
- `Nat < U32`, `Int < IN32`, `Nat < Byte` 같은 broad numeric subsort 없음
- `output.maude`는 Maude에서 정상 load됨

현재 구조의 핵심은 다음이다.

```maude
sort SpectecTerminal .

sort Instr .
subsort Instr < SpectecTerminal .

op CTORLOCALGETA1 : SpectecTerminal -> SpectecTerminal [ctor] .

cmb CTORLOCALGETA1(X) : Instr
 if X : Localidx .
```

즉 constructor는 실제 object/source/runtime term을 만들기 위해
`SpectecTerminal`을 반환하고, 그 term이 어떤 syntax category에 들어가는지는
`mb`, `cmb`, `subsort`로 따로 부여한다.

다만 garbage-term 관점에서는 아직 완전히 정밀하지 않다. 특히 list/sequence
인자와 record field 일부가 `cmb` 조건에서 빠져 있어서, 어떤 constructor는
argument 전체가 원하는 category의 list인지까지는 확인하지 않는다.

## 2. 추출 방법

아래 명령들로 현재 결과를 재현할 수 있다.

```sh
rg -n "sort |sorts |subsort |op |ops |mb |cmb " output.maude
rg -n "SpectecType|SpectecCategory|WasmType|typecheck|hasType|WellTyped|SortCTOR" output.maude
rg -n "subsort Nat < U32|subsort Int < IN32|subsort Nat < Byte" output.maude
maude -no-banner output.maude
```

현재 감사 기준 파일은 `output.maude`이고, 이 파일은 `translator.ml`에서
생성된 결과다. `output.maude`를 손으로 고쳐서 만든 결과가 아니다.

## 3. 전체 수치

현재 `output.maude`에서 기계적으로 추출한 수치는 다음과 같다.

| 항목 | 개수 | 의미 |
|---|---:|---|
| 전체 unique sort | 240 | infrastructure sort + source-derived syntax sort |
| source-derived syntax sort block | 228 | SpecTec syntax category 및 specialization sort |
| subsort edge | 352 | category inclusion, alias, specialization, terminal 연결 |
| op/ops 선언으로 생긴 operator | 1393 | constructor, helper, relation wrapper 포함 |
| `[ctor]` operator | 568 | object/source/runtime constructor 성격의 operator |
| `SpectecTerminal` 반환 operator | 861 | 실제 SpecTec/Wasm term을 만드는 operator 다수 |
| `mb` axiom | 206 | nullary/simple membership 또는 일부 unconditional membership |
| `cmb` axiom | 349 | 조건부 category membership |
| `cmb` 중 조건이 있는 것 | 349 | 현재 `cmb`는 모두 condition을 가진다 |
| subsort cycle | 0 | 추출된 subsort graph에서 cycle 없음 |

중요한 해석:

- `source-derived syntax sort block`은 `output.maude` 1605-1829줄 근처에 있다.
- `subsort` graph는 1830-2163줄 근처에 집중되어 있다.
- 실제 category membership인 `mb/cmb`는 대략 13847-14741줄에 집중되어 있다.

## 4. Sort 구조

### 4.1 Infrastructure sort

이 sort들은 SpecTec syntax category라기보다 Maude encoding substrate다.

| Sort | 위치 | 역할 |
|---|---:|---|
| `SpectecTerminal` | line 2 | 실제 object/source/runtime term의 top sort |
| `SpectecTerminals` | line 10 | terminal sequence carrier |
| `RecordItem`, `RecordItems` | line 37-38 | record encoding substrate |
| `InstrSeq` | line 95 | execution pattern용 instruction sequence refinement |
| `ValSeq` | line 101 | execution pattern용 value sequence refinement |
| `Judgement`, `ValidJudgement` | line 127-128 | relation judgement wrapper |
| `StepConf`, `StepPureConf`, `StepReadConf`, `StepsConf` | line 154 | execution relation wrapper result sorts |

대표 snippet:

```maude
sort SpectecTerminal .
sort SpectecTerminals .
subsort SpectecTerminal < SpectecTerminals .

sort InstrSeq .
subsort Instr < InstrSeq .
subsort InstrSeq < SpectecTerminals .

sort ValSeq .
subsort Val < ValSeq .
subsort ValSeq < SpectecTerminals .
```

### 4.2 Source-derived syntax sort

아래 sort들은 SpecTec syntax declaration에서 온 category 또는
parameterized family의 concrete specialization이다.

전체 source-derived sort 목록은 `output.maude` 1605-1829줄에 있다.
현재 생성된 목록은 다음과 같다.

```text
Absheaptype, Addr, Addrref, Addrtype, Arrayaddr, Arrayinst,
Binop, BinopF32, BinopF64, BinopI32, BinopI64,
Bit, Blocktype, Bshape, Byte, Catch, Cnn, Comptype, Config,
Consttype, Context, Cvtop,
CvtopF32F32, CvtopF32F64, CvtopF32I32, CvtopF32I64,
CvtopF64F32, CvtopF64F64, CvtopF64I32, CvtopF64I64,
CvtopI32F32, CvtopI32F64, CvtopI32I32, CvtopI32I64,
CvtopI64F32, CvtopI64F64, CvtopI64I32, CvtopI64I64,
Data, Dataaddr, Dataidx, Datainst, Datamode, Datatype,
Deftype, Dim, Elem, Elemaddr, Elemidx, Eleminst, Elemmode,
Elemtype, Exnaddr, Exninst, Exp, Export, Exportinst, Expr,
Externaddr, Externidx, Externtype,
F32, F64, FN, FN32, FN64, FNmag,
Fieldidx, Fieldtype, Fieldval, Final, Fnn, Frame, Free,
Func, Funcaddr, Funccode, Funcidx, Funcinst,
Global, Globaladdr, Globalidx, Globalinst, Globaltype,
Half, Heaptype, Hostaddr, Hostfunc,
I128, I32, I64, IN, IN128, IN32, IN64,
Idx, Import, Init, Inn, Instr, Instrtype, Ishape,
Jnn, K, Labelidx, Lane, Laneidx, Lanetype, Limits, List,
Lit, Lnn, Loadop, LoadopF32, LoadopF64, LoadopI32, LoadopI64,
Local, Localidx, Localtype, M, Mem, Memaddr, Memarg, Memidx,
Meminst, Memtype, Module, Moduleinst, Moduletype, Mut,
N, Name, Nonfuncs, Null, Num, Numtype,
Oktypeidx, Oktypeidxnat, Pack, Packtype, Packval, Pnn,
Rectype, Ref, Reftype, Relaxed2, Relaxed4,
Relop, RelopF32, RelopF64, RelopI32, RelopI64,
Result, Resulttype, S33, SN, Shape, Start, State,
Storagetype, Store, Storeop, StoreopF32, StoreopF64,
StoreopI32, StoreopI64, Structaddr, Structinst, Subtype,
Sx, Sz, Table, Tableaddr, Tableidx, Tableinst, Tabletype,
Tag, Tagaddr, Tagidx, Taginst, Tagtype,
Testop, TestopF32, TestopF64, TestopI32, TestopI64,
Type, Typeidx, Typeuse, Typevar,
U128, U16, U31, U32, U64, U8, UN,
Unop, UnopF32, UnopF64, UnopI32, UnopI64,
V128, VN, VN128, Val, Valtype,
Vbinop, Vcvtop, Vec, Vectype,
Vextbinop, Vextternop, Vextunop,
Vloadop, VloadopV128, Vnn,
Vrelop, Vshiftop, Vswizzlop, Vternop, Vtestop,
Vunop, Vvbinop, Vvternop, Vvtestop, Vvunop
```

주의할 점:

- `Numtype`, `Instr`, `Config`, `Val` 같은 것은 SpecTec syntax category다.
- `IN32`, `IN64`, `FN32`, `FN64` 같은 것은 parameterized syntax family를
  finite specialization한 concrete sort다.
- `BinopI32`, `CvtopF32I64`, `LoadopI64` 같은 것도 같은 원리의
  specialization sort다.
- `I32`, `F32` 같은 sort 이름은 constructor 이름과 비슷하지만,
  Maude sort다. 실제 constructor term은 `CTORI32A0`, `CTORF32A0`처럼 따로 있다.

## 5. Subsort 구조

### 5.1 모든 category는 terminal universe 아래로 연결됨

Source-derived category sort는 대체로 `SpectecTerminal` 아래에 연결된다.

예:

```maude
subsort Instr < SpectecTerminal .
subsort Config < SpectecTerminal .
subsort Numtype < SpectecTerminal .
subsort Localidx < SpectecTerminal .
subsort U32 < SpectecTerminal .
subsort IN32 < SpectecTerminal .
```

의미:

```text
Instr term은 SpectecTerminal이다.
Config term은 SpectecTerminal이다.
Numtype term도 실제 Wasm type syntax term이므로 SpectecTerminal이다.
```

이게 맞는 이유는 `Numtype` 자체가 더 이상 `WasmType` 같은 category-tag term이
아니라, `I32`, `I64`, `F32`, `F64` 같은 실제 source term의 category이기 때문이다.

### 5.2 Alias / inclusion chain

SpecTec의 category alias 또는 inclusion은 subsort로 표현된다.

대표 예:

```maude
subsort U32 < Idx .
subsort Idx < Localidx .
```

의미:

```text
syntax idx = u32
syntax localidx = idx
```

가 Maude에서는 `U32 < Idx < Localidx`가 된다.

또 다른 대표 예:

```maude
subsort Numtype < Valtype .
subsort Reftype < Valtype .
subsort Vectype < Valtype .
```

의미:

```text
syntax valtype = numtype | reftype | vectype
```

가 Maude의 category inclusion으로 바뀐다.

### 5.3 Runtime value / administrative instruction inclusion

현재 output에는 다음 관계도 있다.

```maude
subsort Num < Val .
subsort Vec < Val .
subsort Ref < Val .

subsort Val < Instr .
subsort Num < Instr .
subsort Vec < Instr .
subsort Ref < Instr .
subsort Addrref < Instr .
```

이것은 일반 source instruction만이 아니라 runtime execution 중 instruction
sequence 안에 value/admin term이 들어가는 WebAssembly dynamic semantics 구조를
반영한다. 즉 value가 execution configuration 안에서 instruction stream의
일부처럼 나타날 수 있기 때문에 `Val < Instr` 계열 inclusion이 생긴다.

### 5.4 Numeric literal specialization

현재 numeric literal family는 wrapper term + concrete sort로 표현된다.

관련 subsort:

```maude
subsort U32 < IN32 .
subsort U64 < IN64 .
subsort IN32 < Num .
subsort IN64 < Num .
subsort FN32 < Num .
subsort FN64 < Num .
```

의미:

```text
uN(32) < iN(32)
uN(64) < iN(64)
num_(I32) = iN(32) = IN32
num_(I64) = iN(64) = IN64
num_(F32) = fN(32) = FN32
num_(F64) = fN(64) = FN64
```

### 5.5 Broad subsort audit

현재 남아 있는 builtin numeric subsort는 다음이다.

```maude
subsort Nat < SpectecTerminal .
subsort Int < SpectecTerminal .
subsort Nat < Addr .
subsort Nat < K .
subsort Nat < M .
subsort Nat < N .
subsort Int < Exp .
```

이 중 중요한 점:

- `Nat < U32` 없음
- `Int < IN32` 없음
- `Nat < Byte` 없음

따라서 예전에 문제가 됐던 broad numeric approximation은 제거되어 있다.

다만 `Nat < Addr`, `Nat < N` 같은 alias는 여전히 broad하다. 이는 source alias
선언을 반영하기 위한 substrate에 가깝지만, garbage-term audit에서는 따로 봐야
한다. 예를 들어 모든 `Nat`이 `Addr`이 되는 것이 원하는 런타임 주소 모델과
완전히 같은지는 별도 확인 대상이다.

## 6. Operator / term 구조

### 6.1 기본 원칙

현재 object/source/runtime constructor는 대부분 이렇게 선언된다.

```maude
op CTORCONSTA2 : SpectecTerminal SpectecTerminal -> SpectecTerminal [ctor] .
op CTORLOCALGETA1 : SpectecTerminal -> SpectecTerminal [ctor] .
op CTORI32A0 : -> SpectecTerminal [ctor] .
```

즉 operator declaration 자체는 category를 강하게 박지 않는다.

그 대신 membership axiom이 category를 부여한다.

```maude
mb CTORI32A0 : Numtype .

cmb CTORLOCALGETA1(LOCALIDX1) : Instr
 if LOCALIDX1 : Localidx .

cmb CTORCONSTA2(CTORI32A0, NUM1) : Instr
 if NUM1 : IN32 .
```

이 구조는 다음 원칙을 따른다.

```text
operator result sort = SpectecTerminal
category membership = mb/cmb/subsort
```

### 6.2 대표 operator 표

| Operator | 선언 위치 | Declared result | Category membership | 조건 |
|---|---:|---|---|---|
| `CTORI32A0` | line 1104 | `SpectecTerminal` | `Numtype`, `Valtype`, `Inn` 등 | nullary `mb` |
| `CTORLOCALGETA1` | line 1114 | `SpectecTerminal` | `Instr` | argument가 `Localidx` |
| `CTORCONSTA2` | line 1056 | `SpectecTerminal` | `Instr`, `Num`, `Val`, `Fieldval` | first arg에 따라 second arg sort specialization |
| `CTORBLOCKA2` | line 1038 | `SpectecTerminal` | `Instr` | `Blocktype` 조건 있음, instruction list 조건은 약함 |
| `CTORRECA1` | line 1159 | `SpectecTerminal` | `Rectype`, `Heaptype`, `Typevar` 등 | 일부 membership은 list 조건 약함 |
| `RECFrameA2` | line 1363 | `SpectecTerminal` | `Frame` | `Moduleinst` 조건 있음, locals 조건 약함 |
| `RECStoreA10` | line 1370 | `SpectecTerminal` | `Store` | 현재 field 조건 대부분 약함 |
| `litU32` | line 1507 | `SpectecTerminal` | `U32` | `N <= 2^32 - 1` |
| `litU64` | line 1508 | `SpectecTerminal` | `U64` | `N <= 2^64 - 1` |
| `litF32` | line 1502 | `SpectecTerminal` | `FN32` | current Int payload range |
| `litF64` | line 1503 | `SpectecTerminal` | `FN64` | current Int payload range |

### 6.3 Numeric literal wrapper

현재 raw Maude 숫자 `5`를 그대로 `IN32`로 만들지 않는다.

대신 object-level literal wrapper를 사용한다.

```maude
op litU32 : Nat -> SpectecTerminal [ctor] .

cmb litU32(N) : U32
 if N <= 4294967295 = true .
```

그래서 i32 constant는 다음 형태가 된다.

```maude
CTORCONSTA2(CTORI32A0, litU32(5))
```

그리고 membership은 다음 chain으로 성립한다.

```text
litU32(5) : U32
U32 < IN32
CTORCONSTA2(CTORI32A0, litU32(5)) : Instr
```

## 7. Membership axiom 구조

### 7.1 Simple category

예:

```maude
mb CTORI32A0 : Numtype .
mb CTORI64A0 : Numtype .
mb CTORF32A0 : Numtype .
mb CTORF64A0 : Numtype .
```

의미:

```text
I32/I64/F32/F64 constructor term은 Numtype category의 member다.
```

### 7.2 Argumented constructor

예:

```maude
cmb CTORLOCALGETA1(LOCALIDX1) : Instr
 if LOCALIDX1 : Localidx .
```

의미:

```text
LOCAL.GET x는 x가 Localidx일 때만 Instr다.
```

### 7.3 Parameterized family specialization

예:

```maude
cmb CTORCONSTA2(CTORF32A0, NUM1) : Instr
 if NUM1 : FN32 .
cmb CTORCONSTA2(CTORF64A0, NUM1) : Instr
 if NUM1 : FN64 .
cmb CTORCONSTA2(CTORI32A0, NUM1) : Instr
 if NUM1 : IN32 .
cmb CTORCONSTA2(CTORI64A0, NUM1) : Instr
 if NUM1 : IN64 .
```

의미:

```text
CONST T N에서 N의 category가 T에 의존한다.
T = I32이면 N : IN32
T = I64이면 N : IN64
T = F32이면 N : FN32
T = F64이면 N : FN64
```

이 부분은 `N : num_(T)` 같은 invalid Maude encoding을 쓰지 않고,
case-specific sort membership으로 dependency를 보존한다.

### 7.4 Alias / inclusion

예:

```maude
subsort U32 < Idx .
subsort Idx < Localidx .
```

의미:

```text
typecheck(T, localidx) = typecheck(T, idx)
typecheck(T, idx) = typecheck(T, u32)
```

같은 old JHS equation이 새 encoding에서는 subsort chain으로 바뀐다.

## 8. Garbage-term audit

### 8.1 막히는 garbage term

현재 membership encoding이 잘 막는 garbage term이 있다.

예:

```maude
CTORLOCALGETA1(CTORI32A0)
```

이 term은 operator declaration 때문에 `SpectecTerminal`로는 존재할 수 있다.
하지만 `Instr`가 되려면 argument가 `Localidx`여야 한다.

```maude
cmb CTORLOCALGETA1(LOCALIDX1) : Instr
 if LOCALIDX1 : Localidx .
```

`CTORI32A0 : Localidx`가 아니므로, 이 garbage term은 `Instr` membership을
얻지 못한다.

또한 `CONST` dependency도 잘 막는다.

```maude
CTORCONSTA2(CTORI32A0, litU64(5))
```

이 term은 `SpectecTerminal`로는 만들 수 있지만 `Instr`가 되려면 두 번째
argument가 `IN32`여야 한다. `litU64(5)`는 `U64 < IN64` 쪽이므로, 정상적으로는
`IN32`가 아니다.

### 8.2 아직 남은 garbage-term risk

현재 output은 완전히 garbage-free하지 않다. 감사에서 확인된 주요 risk는
다음이다.

#### Risk 1. Sequence/list argument 조건 누락

예:

```maude
cmb CTORBLOCKA2(BLOCKTYPE1, INSTR-LIST-INSTR1) : Instr
 if BLOCKTYPE1 : Blocktype .
```

여기서 두 번째 argument는 원래 `instr*`여야 한다. 하지만 현재 condition은
`BLOCKTYPE1 : Blocktype`만 확인하고, `INSTR-LIST-INSTR1`이 실제 `Instr`들의
sequence인지 확인하지 않는다.

같은 risk가 다음에도 있다.

- `CTORLOOPA2`
- `CTORWIFELSEA3`
- `CTORBRTABLEA2`
- `CTORTRYTABLEA3`
- `CTORLABELLBRACERBRACEA3`
- `CTORFRAMELBRACERBRACEA3`
- `CTORHANDLERLBRACERBRACEA3`
- `CTORMODULEA11`

즉 `SpectecTerminals` carrier가 너무 넓어서 list element category를 완전히
보존하지 못하는 부분이 있다.

#### Risk 2. Some `mb` on argumented constructors

몇몇 argumented constructor가 `cmb`가 아니라 `mb`로 생성되어 argument sort
조건이 없다.

예:

```maude
mb CTORSTRUCTA1(LIST1) : Comptype .
mb CTORARRAYA1(FIELDTYPE1) : Comptype .
mb CTORFUNCARROWA2(RESULTTYPE1, RESULTTYPE2) : Comptype .
mb CTORRECA1(LIST1) : Rectype .
mb CTORARROWA2(EXTERNTYPE-LIST-EXTERNTYPE1, EXTERNTYPE-LIST-EXTERNTYPE2) : Moduletype .
mb CTORARROWA3(RESULTTYPE1, LOCALIDX-LIST-LOCALIDX1, RESULTTYPE2) : Instrtype .
```

이들은 garbage-term risk다. 예를 들어 `CTORARRAYA1(X)`가 `Comptype`가 되려면
`X : Fieldtype`이어야 하는데, 현재 unconditional `mb`이면 그 조건이 없다.

#### Risk 3. Record field condition이 부분적으로만 존재

예:

```maude
cmb RECFrameA2(F-FRAME-LOCALS-0, F-FRAME-MODULE-1) : Frame
 if F-FRAME-MODULE-1 : Moduleinst .
```

여기서 `MODULE` field는 확인하지만 `LOCALS` field는 확인하지 않는다.

비슷한 risk:

- `Frame`: locals field condition 약함
- `Store`: tags/globals/mems/tables/functions/data/elements/structs/arrays/exns field condition 약함
- `Meminst`: bytes field condition 약함
- `Tableinst`: refs field condition 약함
- `Context`: 대부분의 list field condition 약함

#### Risk 4. `Config` membership이 instruction list를 충분히 보지 않음

현재:

```maude
cmb (STATE1 ; INSTR-LIST-INSTR1) : Config
 if STATE1 : State .
```

즉 state가 `State`이면 config가 되고, instruction sequence argument가 실제
`Instr` sequence인지까지는 membership condition에서 확인하지 않는다.

이것은 현재 가장 중요한 garbage-term risk 중 하나다. 실제 runtime harness에는
대부분 정상 term이 들어오지만, syntax universe 자체는 다음 같은 모양을 막지
못할 수 있다.

```maude
STATE ; GARBAGE_TERMINALS
```

#### Risk 5. Vector operator specialization 일부 조건 누락

예:

```maude
cmb CTORVUNOPA2(SHAPE1, VUNOP1) : Instr
 if SHAPE1 : Shape .
```

여기서 `VUNOP1`이 해당 shape에 맞는 `vunop_(shape)` 계열인지 확인하는 조건이
약하다. 비슷한 risk가 `VBINOP`, `VTERNOP`, `VTESTOP`, `VRELOP`, `VSHIFTOP`,
`VEXTUNOP`, `VEXTBINOP`, `VEXTTERNOP`, `VCVTOP` 등에 남아 있다.

## 9. 현재 구조가 올바른가?

큰 방향은 올바르다.

현재 구조는 다음 목표를 만족한다.

- category-as-term 제거
- `SpectecType`/`WasmType` 제거
- Boolean `typecheck` 제거
- constructor는 `SpectecTerminal` 반환
- category membership은 `mb/cmb/subsort`
- parameterized family는 concrete sort로 specialize
- numeric literal은 object-level wrapper로 표현

하지만 완전히 정밀한 syntax grammar는 아직 아니다.

현재 남은 문제는 old JHS 방식으로 돌아간 문제가 아니라, 새 membership 기반
encoding 안에서 list/sequence/record argument precision이 아직 부족한 문제다.

정리하면:

```text
좋은 점:
  old type-tag encoding 제거 완료
  대표 syntax pattern은 Maude-native membership으로 바뀜
  CONST 같은 dependency-sensitive syntax도 case split으로 표현됨

남은 점:
  list/sequence category membership이 너무 넓음
  일부 argumented constructor가 unconditional mb로 남아 있음
  Config/Store/Frame 같은 runtime container의 field precision이 약함
```

## 10. 교수님께 설명할 때의 핵심 문장

다음처럼 말하면 된다.

```text
기존에는 syntax category를 WasmType term으로 만들고
typecheck(term, category-term)으로 membership을 판단했습니다.

현재는 syntax category를 Maude sort로 만들고,
actual syntax/runtime term은 SpectecTerminal로 만든 뒤,
mb/cmb/subsort로 category membership을 부여합니다.

전체 output을 audit해 보니 source-derived sort는 228개,
subsort edge는 352개, membership axiom은 555개입니다.
SpectecType/WasmType/typecheck/SortCTOR는 남아 있지 않습니다.

다만 garbage-free 관점에서는 아직 sequence/list 인자와 record field의
membership condition이 약한 곳이 남아 있습니다.
특히 Config, Block, Loop, Module, Store, Frame 쪽은 실제 Wasm configuration에
안 나오는 garbage-looking term도 category membership을 받을 수 있어
다음 단계에서 정밀화가 필요합니다.
```

## 11. 다음 작업 후보

다음 단계는 runtime execution을 만지는 것이 아니라 syntax precision을 더
좁히는 쪽이 맞다.

우선순위:

1. `X*` sequence sort를 실제 element category와 연결하기
   - 예: `InstrList`, `ValtypeList`, `LocalList`, `ExprList`
   - `Instr*` argument가 단순 `SpectecTerminals`가 아니라 `InstrSeq` 또는
     category-specific sequence sort를 요구하게 만들기

2. argument가 있는데 `mb`로 나온 constructor를 `cmb`로 바꾸기
   - 예: `CTORARRAYA1(FIELDTYPE1) : Comptype`
   - 예: `CTORFUNCARROWA2(RESULTTYPE1, RESULTTYPE2) : Comptype`

3. record constructor field membership 정밀화
   - `Frame.locals`
   - `Store.tags/globals/mems/...`
   - `Context.types/locals/labels/...`

4. `Config` membership 정밀화
   - 현재는 `STATE1 : State`만 확인
   - 목표는 instruction stream도 `InstrSeq` 또는 equivalent condition을 요구

5. vector family specialization condition 보강
   - `vunop_(shape)`, `vbinop_(shape)`, `vcvtop__(...)` 등의 second/third argument
     family membership을 shape/type parameter와 함께 보존

이 작업들은 모두 `translator.ml`에서 AST-driven하게 처리해야 한다. 특정
instruction 이름을 찍어서 고치는 방식으로 하면 안 된다.

