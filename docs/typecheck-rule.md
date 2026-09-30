# Typecheck rule
우리의 목표는 wasm program modelchecking이다. 
input wasm program은 spec2maude에 들어오기전에, wasm frontend validator의 검증을 거친다. 
wasm frontend validator는 프로그램을 처음 받았을 때, 타입체크를 한다.
따라서 spec2maude의 input은 type이 보장되어 있음. -> maude에서 타입체크를 또 할 필요가 없고, 그러므로 spectec의 typecheck rule을 번역할 필요가 없다.

근데 우리가 번역해야하는 실행 rule, def의 condition에 typecheck rule 및 typecheck 관련 연산이 있는 경우가 5가지 존재한다.
이 경우는 두 가지로 나뉜다. 
1. condition이 타입체크인 경우 (즉, 보장된 타입을 재검사하는 경우)
     그 연산의 cond에 hint(no_maude_translate)를 줘서 건너뛴다.
     ex) rule postech: a ~> b
              --- if a가 올바른 타입 hint(no_maude_translate "-- if a가 올바른 타입")
          이면 rl postech : a => b . 로 번역
2. condition에 따라 실행 중 rule의 실행이 결정되는 경우 or 실행에 필요한 정보를 구하는 계산
     이때는 번역해야한다. 이때는 따로 hint를 줘서 번역한다.

이제 이 5가지에 대해 모두 살펴보자.

## 1. Expand (타입 정의에서 실제 내용을 꺼냄)
1. 이를 사용하는 SpecTec
    ```ocaml
    def $blocktype_(state, blocktype) : instrtype
    
    def $blocktype_(z, _IDX x) = t_1* -> t_2*
      -- Expand: $type(z, x) ~~ FUNC t_1* -> t_2*
    ```
    - 의미: 블록의 타입이 번호 x로 주어졌으므로, state에서 해당 타입을 찾아 “입력 타입 리스트 `t_1*`와 결과 타입 리스트 `t_2*`”를 꺼낸다.
        여기서 $type(z, x)는 타입을 찾고, Expand는 찾은 타입의 내용을 펼쳐 본다.
        
2. Expand
    ```ocaml
    relation Expand: deftype ~~ comptype hint(maude_compute)
    
    rule Expand:
      deftype ~~ comptype
      -- if $unrolldt(deftype) = SUB final? typeuse* comptype
    ```
    
    - 의미: $unrolldt(deftype)의 결과에서 마지막 부분인 comptype를 꺼낸다
        - deftype: 정의된 타입 하나
        - $unrolldt(deftype): 그 타입의 정의 내용을 꺼내는 함수 
        - SUB: 여기부터 subtype 정의다라는 표시 
        - final?: 이 타입을 상속할 수 없다는 FINAL 표시가 있거나 없음 
        - typeuse*: 이 타입이 상속하는 상위 타입들의 리스트
        - comptype: 실제 타입 내용 (함수면 입출력 타입 / 구조체면 필드들 / 배열이면 원소 타입)
        
3. Expand to Maude
    ```ocaml
    op expand : SpectecTerminal ~> SpectecTerminal .
    
    ceq expand(DEFTYPE) = COMPTYPE
    	if SUB(FINAL-, TYPEUSE-, COMPTYPE) := unrolldt(DEFTYPE)
    	/\ len(FINAL-) <= 1 .
    ```
    
## 2. Ref_ok (실행 중 참조 값을 특정 타입으로 사용할 수 있는지 검사)
REF는 참조 타입이라는 뜻이다. 
참조는 Wasm 값의 한 종류로, 함수나 객체를 가리킬 수도 있고 null일 수도 있음.

1. 이를 사용하는 SpecTec
```
rule Step_read/ref.test-true:
  s; f; ref (REF.TEST rt) ~> (CONST I32 1)
  -- Ref_ok: s |- ref : $inst_reftype(f.MODULE, rt)
```
의미: 실행 중 참조 값 ref가 목표 타입 rt에 부합하면 1을 반환한다는 규칙이다.

Validator는 REF.TEST rt라는 명령어가 올바르다는 것을 보장한다. 하지만 실행 중 들어오는 실제 참조 값 ref가 반드시 rt에 부합한다고 보장하지는 않는다.
따라서 프로그램을 실행하면서 실제 ref가 목표 타입에 부합하는지 검사해야 한다. -> Ref_ok는 동적 타입 검사이므로 변환해야한다.

2. Ref_ok와 변환한 Maude
  **1. `Ref_ok/null`**
  ```Spectec
  relation Ref_ok: store |- ref : reftype hint(maude_base-check)

  rule Ref_ok/null:
    s |- REF.NULL_ADDR : REF NULL BOT
  ```
  의미: 
  - `s |- 값 : 타입`은 “store s에서 이 값을 이 타입으로 인정한다”는 판단이다.
  - 따라서 `s |- REF.NULL_ADDR`라는 null 값을 `REF NULL BOT` 타입으로 판단한다는 뜻

  ```maude
  op ref-ok : SpectecTerminal val -> SpectecTerminal .

  eq ref-ok(STORE, REF.NULL-ADDR) = REF(NULL ?, BOT) .
  ```
  REF(NULL ?, BOT)는 null만 들어올 수 있는 참조 타입이라는 뜻임.
  - NULL?: null 허용
  - BOT: null이 아닌 실제 대상을 넣을 수 있는 종류가 없음

  ---

  **2. `Ref_ok/i31`**
  ```Spectec
  rule Ref_ok/i31:
    s |- REF.I31_NUM i : REF I31
  ```
  의미: i31 참조 값(REF.I31_NUM) i는 REF I31 타입이다 
  (참조 값: wasm에서 어떤 대상을 가리키거나 나타내는 값)

  ```maude
  eq ref-ok(STORE, REF.I31-NUM(I)) = REF(eps, I31) .
  ```
  여기서 `REF(eps, I31)`은 원문의 `REF I31`임. `REF(eps, I31)`는 null은 안 되고, i31 참조 값만 받을 수 있는 타입이라는 뜻임.

  ---

  **3. `Ref_ok/struct`**
  ```text
  rule Ref_ok/struct:
    s |- REF.STRUCT_ADDR a : REF dt
    -- if s.STRUCTS[a].TYPE = dt
  ```
  의미: 주소 `a`의 struct에 기록된 타입이 `dt`이면, 그 참조 REF.STRUCT_ADDR a는 REF dt 타입이다
  - REF.STRUCT_ADDR a: 주소 a에 struct가 저장되어 있으면, REF.STRUCT_ADDR a는 주소 a의 struct를 가리킴 (struct 내용 자체가 아니라 그 struct를 찾아갈 수 있는 참조)

  ```maude
  ceq ref-ok(STORE, REF.STRUCT-ADDR(A)) = REF(eps, DT)
    if indexDefined(STORE . 'STRUCTS, A) --- store에 A번 struct가 있는가?
    /\ INST := (STORE . 'STRUCTS) [ A ] --- 그 struct를 INST로 읽음
    /\ DT := INST . 'TYPE . --- TYPE을 dt로 읽음
  ```

  ---

  **4. `Ref_ok/array`**
  ```text
  rule Ref_ok/array:
    s |- REF.ARRAY_ADDR a : REF dt
    -- if s.ARRAYS[a].TYPE = dt
  ```
  의미: 주소 `a`의 array에 기록된 타입이 `dt`이면, 그 참조는 `REF dt` 타입이다

  ```maude
  ceq ref-ok(STORE, REF.ARRAY-ADDR(A)) = REF(eps, DT)
    if indexDefined(STORE . 'ARRAYS, A)
      /\ INST := (STORE . 'ARRAYS) [ A ]
      /\ DT := INST . 'TYPE .
  ```

  ---

  **5. `Ref_ok/func`**
  ```text
  rule Ref_ok/func:
    s |- REF.FUNC_ADDR a : REF dt
    -- if s.FUNCS[a].TYPE = dt
  ```
  의미: 주소 `a`의 함수에 기록된 타입이 `dt`이면, 그 함수 참조는 `REF dt` 타입이다.

  ```maude
  ceq ref-ok(STORE, REF.FUNC-ADDR(A)) = REF(eps, DT)
    if indexDefined(STORE . 'FUNCS, A)
      /\ INST := (STORE . 'FUNCS) [ A ]
      /\ DT := INST . 'TYPE .
  ```

  ---

  **6. `Ref_ok/exn`**
  ```text
  rule Ref_ok/exn:
    s |- REF.EXN_ADDR a : REF EXN
    -- if s.EXNS[a] = exn 
  ```
  의미: 주소 `a`에 예외 객체가 있으면, 그 참조는 `REF EXN` 타입이다.
  - s.EXNS[a] = exn: store의 EXNS에서 a번 예외 객체를 꺼내서 exn이라고 부르자.
  - 근데 exn을 안쓰므로 그냥 EXNS에 객체가 있는지만 확인하면 됨 (자동 변환에서 힘들다면 그냥 변환하자)

  ```maude
  ceq ref-ok(STORE, REF.EXN-ADDR(A)) = REF(eps, EXN)
    if indexDefined(STORE . 'EXNS, A) .
  ```

  ---

  **7. `Ref_ok/host`**
  ```text
  rule Ref_ok/host:
    s |- REF.HOST_ADDR a : REF ANY
  ```
  의미: host 참조를 `REF ANY` 타입으로 인정한다. 

  ```maude
  eq ref-ok(STORE, REF.HOST-ADDR(A)) = REF(eps, ANY) .
  ```

  ---

  **8. `Ref_ok/extern`**
  ```text
  rule Ref_ok/extern:
    s |- REF.EXTERN ref : REF EXTERN
    -- Ref_ok: s |- ref : REF ANY
    -- if ref =/= REF.NULL_ADDR
  ```
  의미: 내부 참조 `ref`가 다음 조건을 만족하면, 감싼 값 `REF.EXTERN ref`를 `REF EXTERN` 타입으로 인정한다.
  - 내부 참조를 `REF ANY` 타입으로 사용할 수 있다.
  - 내부 참조가 null이 아니다.

  ```maude
  ceq ref-ok(STORE, REF.EXTERN(R)) = REF(eps, EXTERN)
    if R =/= REF.NULL-ADDR
    /\ ref-ok-sub(STORE, R, REF(eps, ANY)) .
  ```

  ---

  **9. `Ref_ok/sub`**

  ```text
  rule Ref_ok/sub: hint(maude_skip "Reftype_ok")
    s |- ref : rt
    -- Ref_ok: s |- ref : rt'
    -- Reftype_ok: {} |- rt : OK   
    -- Reftype_sub: {} |- rt' <: rt   
  ```
  의미: 다음 세 조건을 만족하면 `ref`를 `rt` 타입으로 인정한다.
  1. `ref`를 `rt'` 타입으로 인정할 수 있다.
  2. 요청한 타입 `rt`가 올바른 타입이다.
  3. `rt'` 타입의 값을 `rt` 자리에서도 사용할 수 있다.
  예를 들어 **`REF I31` 타입의 참조를 `REF ANY` 자리에서도 사용할 수 있다**는 판단이다.

  ```maude
  op ref-ok-sub : SpectecTerminal val SpectecTerminal -> Bool .

  ceq ref-ok-sub(S, R, RT) = true
    if RT- := ref-ok(S, R)
    /\ reftype-sub({ EMPTY }, RT-, RT) .   

  eq ref-ok-sub(S, R, RT) = false [owise] .
  ```

3. ref-ok의 조건에 있는 typecheck rule들
reftype-sub:
  ```Spectec
  relation Reftype_sub: context |- reftype <: reftype hint(maude_check)

  rule Reftype_sub/nonnull:
  C |- REF ht_1 <: REF ht_2
  -- Heaptype_sub: C |- ht_1 <: ht_2   

  rule Reftype_sub/null:
  C |- REF NULL? ht_1 <: REF NULL ht_2
  -- Heaptype_sub: C |- ht_1 <: ht_2   
  ```
  
  ```maude
  op reftype-sub : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .

  ceq reftype-sub(C, REF(eps, HT-1), REF(eps, HT-2)) = true 
    if heaptype-sub(C, HT-1, HT-2) .
  ceq reftype-sub(C, REF(eps, HT-1), REF(NULL ?, HT-2)) = true 
    if heaptype-sub(C, HT-1, HT-2) .
  ceq reftype-sub(C, REF(NULL ?, HT-1), REF(NULL ?, HT-2)) = true 
    if heaptype-sub(C, HT-1, HT-2) .
  ```

heaptype-sub:
  ```Spectec
  relation Heaptype_sub: context |- heaptype <: heaptype hint(maude_sub-check)
  
  rule Heaptype_sub/refl:
  C |- heaptype <: heaptype
  
  rule Heaptype_sub/trans:
  C |- heaptype_1 <: heaptype_2
  -- Heaptype_ok: C |- heaptype' : OK   
  -- Heaptype_sub: C |- heaptype_1 <: heaptype'
  -- Heaptype_sub: C |- heaptype' <: heaptype_2

  rule Heaptype_sub/eq-any:
  C |- EQ <: ANY

  rule Heaptype_sub/i31-eq:
  C |- I31 <: EQ

  rule Heaptype_sub/struct-eq:
  C |- STRUCT <: EQ

  rule Heaptype_sub/array-eq:
  C |- ARRAY <: EQ

  rule Heaptype_sub/struct:
  C |- deftype <: STRUCT
  -- Expand: deftype ~~ STRUCT fieldtype*

  rule Heaptype_sub/array:
  C |- deftype <: ARRAY
  -- Expand: deftype ~~ ARRAY fieldtype

  rule Heaptype_sub/func:
  C |- deftype <: FUNC
  -- Expand: deftype ~~ FUNC t_1* -> t_2*

  rule Heaptype_sub/def:
  C |- deftype_1 <: deftype_2
  -- Deftype_sub: C |- deftype_1 <: deftype_2 

  rule Heaptype_sub/typeidx-l:
  C |- _IDX typeidx <: heaptype
  -- Heaptype_sub: C |- C.TYPES[typeidx] <: heaptype
  
  rule Heaptype_sub/typeidx-r:
  C |- heaptype <: _IDX typeidx
  -- Heaptype_sub: C |- heaptype <: C.TYPES[typeidx]

  rule Heaptype_sub/rec-struct:
  C |- REC i <: STRUCT
  -- if C.RECS[i] = SUB final? (STRUCT fieldtype*)

  rule Heaptype_sub/rec-array:
  C |- REC i <: ARRAY
  -- if C.RECS[i] = SUB final? (ARRAY fieldtype)

  rule Heaptype_sub/rec-func:
  C |- REC i <: FUNC
  -- if C.RECS[i] = SUB final? (FUNC t_1* -> t_2*)

  rule Heaptype_sub/rec-sub:
  C |- REC i <: typeuse*[j]
  -- if C.RECS[i] = SUB final? typeuse* ct

  rule Heaptype_sub/none:
  C |- NONE <: heaptype
  -- Heaptype_sub: C |- heaptype <: ANY
  -- if heaptype =/= BOT

  rule Heaptype_sub/nofunc:
  C |- NOFUNC <: heaptype
  -- Heaptype_sub: C |- heaptype <: FUNC
  -- if heaptype =/= BOT

  rule Heaptype_sub/noexn:
  C |- NOEXN <: heaptype
  -- Heaptype_sub: C |- heaptype <: EXN
  -- if heaptype =/= BOT

  rule Heaptype_sub/noextern:
  C |- NOEXTERN <: heaptype
  -- Heaptype_sub: C |- heaptype <: EXTERN
  -- if heaptype =/= BOT

  rule Heaptype_sub/bot:
  C |- BOT <: heaptype
  ```

  ```maude
  op heaptype-sub : SpectecTerminal SpectecTerminal SpectecTerminal ~> Bool .

  eq heaptype-sub(C, HEAPTYPE, HEAPTYPE) = true .

  ceq heaptype-sub(C, H1, H2) = true --- 중간 타입 탐색 미구현 -> 구현 필요
  if heaptype-sub(C, H1, H-)
    /\ heaptype-sub(C, H-, H2) .

  eq heaptype-sub(C, EQ, ANY) = true .

  eq heaptype-sub(C, I31, EQ) = true .

  eq heaptype-sub(C, STRUCT, EQ) = true .

  eq heaptype-sub(C, ARRAY, EQ) = true .

  ceq heaptype-sub(C, DEFTYPE, STRUCT) = true
    if spectec-Struct(FIELDTYPE-) := expand(DEFTYPE) .

  ceq heaptype-sub(C, DEFTYPE, ARRAY) = true
    if spectec-ARRAY(FIELDTYPE-) := expand(DEFTYPE) . 

  ceq heaptype-sub(C, DEFTYPE, spectec-FUNC) = true
    if FUNC T-1- -> T-2- := expand(DEFTYPE) . 

  ceq heaptype-sub(C, DEFTYPE1, DEFTYPE2) = true
    if deftype-sub(C, DEFTYPE1, DEFTYPE2) . 

  ceq heaptype-sub(C, -IDX(TYPEIDX), HEAPTYPE) = true
    if heaptype-sub(C, (C . 'TYPES) [ TYPEIDX ], HEAPTYPE) .

  ceq heaptype-sub(C, HEAPTYPE, -IDX(TYPEIDX)) = true
    if heaptype-sub(C, HEAPTYPE, (C . 'TYPES) [ TYPEIDX ]) .

  ceq heaptype-sub(C, REC(I), STRUCT) = true
    if SUB(FINAL-, eps, spectec-STRUCT(FIELDTYPE-)) := (C . 'RECS) [ I ]
      /\ len(FINAL-) <= 1 .

  ceq heaptype-sub(C, REC(I), ARRAY) = true
    if SUB(FINAL-, eps, spectec-ARRAY(FIELDTYPE)) := (C . 'RECS) [ I ]
      /\ len(FINAL-) <= 1 .

  ceq heaptype-sub(C, REC(I), spectec-FUNC) = true
    if SUB(FINAL-, eps, FUNC T-1- -> T-2-) := (C . 'RECS) [ I ]
      /\ len(FINAL-) <= 1 .

  ceq heaptype-sub(C, REC(I), HT) = true
    if SUB(FIN, TUS, CT) := (C . 'RECS)[I]   
      /\ PREFIX HT SUFFIX := TUS .        

  ceq heaptype-sub(C, NONE, HEAPTYPE) = true
    if heaptype-sub(C, HEAPTYPE, ANY)
    /\ HEAPTYPE =/= BOT .

  ceq heaptype-sub(C, NOFUNC, HEAPTYPE) = true
    if heaptype-sub(C, HEAPTYPE, spectec-FUNC)
    /\ HEAPTYPE =/= BOT . 

  ceq heaptype-sub(C, NOEXN, HEAPTYPE) = true
    if heaptype-sub(C, HEAPTYPE, EXN)
    /\ HEAPTYPE =/= BOT . 

  ceq heaptype-sub(C, NOEXTERN, HEAPTYPE) = true
    if heaptype-sub(C, HEAPTYPE, EXTERN)
    /\ HEAPTYPE =/= BOT . 
  
  eq heaptype-sub(C, BOT, HEAPTYPE) = true .
  ```

deftype-sub:
  ```Spectec
  relation Deftype_sub: context |- deftype <: deftype hint(maude_sub-check)

  rule Deftype_sub/refl:
  C |- deftype_1 <: deftype_2
  -- if clos_deftype(C, deftype_1) = clos_deftype(C, deftype_2)

  rule Deftype_sub/super:
  C |- deftype_1 <: deftype_2
  -- if unrolldt(deftype_1) = SUB final? typeuse* ct
  -- Heaptype_sub: C |- typeuse*[i] <: deftype_2
  ```

  ```maude
  op deftype-sub : SpectecTerminal SpectecTerminal SpectecTerminal -> Bool .

  ceq deftype-sub(C, DEFTYPE1, DEFTYPE2) = true
    if clos-deftype(C, DEFTYPE1) == clos-deftype(C, DEFTYPE2) .
  
  ceq deftype-sub(C, DEFTYPE1, DEFTYPE2) = true
    if SUB(FINAL, TYPEUSE-, CT) := unrolldt(DEFTYPE1)
    /\ PREFIX TU SUFFIX := TYPEUSE-     
    /\ heaptype-sub(C, TU, DEFTYPE2) .
  ```

## 3. Val-ok (함수에 넘긴 실제 인자의 타입을 검사)
1. 이를 사용하는 SpecTec
```spectec
def $invoke(store, funcaddr, val*) : config

def $invoke(s, funcaddr, val*) =
  s; {MODULE {}};
  val* (REF.FUNC_ADDR funcaddr) (CALL_REF s.FUNCS[funcaddr].TYPE)
  ----
  -- Expand: s.FUNCS[funcaddr].TYPE ~~ FUNC t_1* -> t_2*
  -- (Val_ok: s |- val : t_1)*
```
의미: store s의 funcaddr가 가리키는 함수를 주어진 인자 val*로 호출하기 위한 initial config를 만드는 함수
- invoke의 RHS에 대해 알아보자
  - s: 현재 store (이미 인스턴스화 된 함수와 메모리 등이 드렁있는 store를 그대로 사용)
  - {MODULE {}}: 실행에 사용할 Frame (frame에는 현재 함수의 실행 정보가 들어있기 때문에 처음에는 아무것도 없음)
  - val* (REF.FUNC_ADDR funcaddr) (CALL_REF s.FUNCS[funcaddr].TYPE): 실제 함수 호출을 준비하는 명령어들
    - val*: 함수에 전달할 인자들을 실행 스택에 배치
    - REF.FUNC_ADDR funcaddr: 호출할 함수를 가리키는 함수 참조를 배치
    - CALL_REF s.FUNCS[funcaddr].TYPE: 해당 함수의 타입을 지정하여 함수 참조를 호출하는 명령
- 전제 조건을 살펴보자
  - Expand: 함수의 input/output 타입을 알아낸다
  - Val_ok: 전달할 값(val)의 타입이 실제 함수에서 요구하는 타입에 부합하는지 확인
            **사용자의 input이 올바른지 확인하기 위해 Val_ok를 변환해야한다 !**

2. Val_ok
```spectec
relation Val_ok: store |- val : valtype hint(maude_check)

rule Val_ok/num:
  s |- num : nt
  -- Num_ok: s |- num : nt

rule Val_ok/vec:
  s |- vec : vt
  -- Vec_ok: s |- vec : vt

rule Val_ok/ref:
  s |- ref : rt
  -- Ref_ok: s |- ref : rt
```
의미: 값의 종류에 따라 검사를 맡김
- 숫자 -> `Num_ok`
- 벡터 -> `Vec_ok`
- 참조 -> `Ref_ok`

3. Val_ok to maude
```maude
op val-ok : SpectecTerminal val SpectecTerminal ~> Bool .

ceq val-ok(S, NUM, NT) = true
  if num-ok(S, NUM, NT) .

ceq val-ok(S2, VEC, VT) = true
  if vec-ok(S2, VEC, VT) .

ceq val-ok(S2, REF2, RT) = true
  if ref-ok-sub(S2, REF2, RT) .
```

4. val-ok의 조건에 있는 typecheck rule들
ref-ok는 이미 변환했으니, num-ok랑 vec-ok만 변환하면 됨.
```spectec
relation Num_ok: store |- num : numtype hint(maude_check)

rule Num_ok:
  s |- CONST nt c : nt   ;;  숫자 값 CONST nt c의 타입이 nt임을 판단

relation Vec_ok: store |- vec : vectype hint(maude_check)

rule Vec_ok:
  s |- VCONST vt c : vt ;; 벡터 값 VCONST vt c의 타입이 vt임을 판단
```

```maude
op num-ok : SpectecTerminal val SpectecTerminal -> Bool .
eq num-ok(S, CONST(NT, C), NT) = true .

op vec-ok : SpectecTerminal val SpectecTerminal -> Bool .
eq vec-ok(S, VCONST(VT, C), VT) = true .
```

## 4. Module_ok & Externaddr_ok
1. 이를 사용하는 SpecTec
```spectec
def $instantiate(store, module, externaddr*) : config hint(maude_skip "Module_ok" "Externaddr_ok")
def $instantiate(s, module, externaddr*) = s''''; {MODULE moduleinst}; instr_E* instr_D* instr_S?
  ---- ----
  -- Module_ok: |- module : xt_I* -> xt_E*
  -- (Externaddr_ok: s |- externaddr : xt_I)*
  ---- ...
```
의미: 
  - fac.wat를 실행하려면 먼저 모듈에 정의된 함수 등을 실제 실행 환경(store & module instance)에 등록해야함. 이 작업을 instantiation(인스턴스화)라고 함.
  - 즉 모듈의 함수, 메모리, 전역 변수 등을 생성하고 초기화 할 실행 설정을 준비함
  - 이후 invoke가 인스턴스화 된 모듈에서 특정 함수를 인자와 함께 호출할 initial config를 만듬

$instantiate의 입력:
  - store s: 현재 store
  - module: 인스턴스화하려는 wasm 모듈 (ex: fac.wat)
  - externaddr*: 모듈이 import하는 외부 객체들의 주소 목록 (다른 module에서 가져온 함수나 메모리 등의 주소를 나타냄. import가 없으면 빈 list.)

$instantiate의 반환 값(RHS):
  - s'''': 필요한 인스턴스를 할당한 최종 state
  - moduleinst: 생성된 모듈 인스턴스
  - instr_E*: Element segment 초기화 명령어
  - instr_D*: Data segment 초기화 명령어
  - instr_S?: Start function 호출 명령어 (있을 경우)

$instantiate의 전제 조건: 모듈 및 import 검사
  a. Module_ok: 모듈의 정적 타입 검사
     - 모듈이 올바른지 검사한다
       - 여기서 모듈은 instantiate의 input module (ex: fac.wat)
       - 그니까 fac.wat의 타입이 올바른지 검사하는건데, 애초에 fac.wat은 wasm frontend validator를 통과해서 타입이 반환되므로 Module_ok를 할 필요가 없음
     - 근데 Module_ok가 뱉는 xt_I*(모듈이 요구하는 Import 타입 목록)은 필요함. 왜냐하면 Externaddr_ok에서 쓰이기 때문.
       **그러면 Module_ok에서 타입체크를 빼고 xt_I*만 뱉게끔 변환하던가, 손으로 module-ok(...) = XT-I- . 를 구현해야겠네**
  b. Externaddr_ok: 실제 Import 연결 검사
     - externaddr*: 실제로 전달받은 외부 함수/메모리 등의 주소 목록
     - xt_I*: 모듈이 요구하는 Import 타입 목록
     => externaddr*로 전달된 외부 함수/메모리 등의 타입이 모듈에서 요구하는 Import 타입(xt_I*)와 호환되는지 검사
     **frontend validator는 실제 Import 연결까지 검증하지 않으므로, 전달된 externaddr*가 모듈의 Import 타입과 호환되는지 검사해야함 -> 따라서 번역해야함**
  **근데 import를 지금 지원안할것임 -> 이는 나중으로 미루자 -> Module_ok랑 Externaddr_ok 다 변환할 필요가 없음**

**$instantiate를 변환할 때는 Module_ok랑 Externaddr_ok에 hint(maude_no_translate ..)등을 붙여서 변환을 안하면 됨. 나머진 다 변환하고**

## 5. 이제 손으로 아이디어 구상은 끝났다. 이제 main branch에서 현재 방식(relation-backends.maude)를 없애고 hint를 이용해 모두 자동화 해야한다.
- 어떻게 어디에 hint를 붙여서
- 어떻게 변환을 할지
- 최대한 간단하게, 재귀적인 변환기를 유지하며 변환 방법론을 구상해야한다.
- 그리고 변수명 등도 정리해야함
- 중요: wasm2maude가 인자의 타입을 체크 -> 말도안됨. val-ok가 해야함. 이제 val-ok 번역하므로, 이거 수정해야함.
