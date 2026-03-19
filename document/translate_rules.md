# SpecTec → Maude 변환 규칙 공식 문서

SpecTec IL AST가 Maude 대수 명세로 변환되는 모든 변환 규칙을 정의한다.

**표기법 (실전 압축)**:
- `sanitize(id)` : 식별자 정규화
- `_^N` : 믹스픽스 파라미터 슬롯 N개
- `WasmTerminal^N` : WasmTerminal 타입 N개
- `V_1 ... V_N` : 변수 나열
- `is-type(V_1, S_1) and ... and is-type(V_N, S_N)` : 파라미터 타입 검사 논리곱

---

## 1. translate_typd (TypD)

`syntax type` 정의를 Maude `op` 선언과 `eq`/`ceq` 방정식으로 변환한다.

### 1.1 요약 표

| 패턴명 | 조건 | 변환 방식 |
|--------|------|------------|
| 타입 op 선언 | id ∉ base_types | `op sanitize(id) : WasmTerminal^|params| -> WasmType [ctor] .` |
| VariantT-단순키워드 | N=0, prems=∅ | `op sanitize(mixop) : -> WasmTerminal [ctor] .` + `eq is-type(sanitize(mixop), Type_id) = true .` |
| VariantT-인자포함 | N>0, prems=∅, 옵셔널 아님 | `op sanitize(mixop) _^N : WasmTerminal^N -> WasmTerminal [ctor] .` + `eq is-type(sanitize(mixop) V_1 ... V_N, Type_id) = is-type(V_1, S_1) and ... and is-type(V_N, S_N) .` |
| VariantT-옵셔널 | IterT(_, Opt) 포함 | 위 + `eq is-type(..., eps, ...) = ...` 추가 방정식 |
| VariantT-전제조건 | prems ≠ ∅ | `ceq is-type(i_var, Type_id) = true if binder_conds and prem_conds .` |
| AliasT | deftyp = AliasT(typ) | `eq is-type(T/TS, Type_id) = is-type(T, typ) .` |
| StructT | deftyp = StructT(fields) | `eq is-type({item('F1,V1);...}, Type_id) = is-type(V1,S1) and ... .` |

### 1.2 실전 압축 수도코드

```
[[ TypD(id, params, insts) ]] =>
    op sanitize(id) : WasmTerminal^|params| -> WasmType [ctor] .

    insts 내의 각 InstD(binders, args, deftyp)에 대해:
        --- Type_id: 부모 타입 이름 (예: "numtype" 또는 파라미터가 있다면 "binop(NT)")
        let args_str = args를 콤마(,)로 연결한 문자열
        let Type_id = if args_str == "" then sanitize(id) else sanitize(id) ^ "(" ^ args_str ^ ")"

        if deftyp == VariantT(cases):
            cases 내의 각 (mixop, (_, case_typ, prems), _)에 대해:
                let N = |case_typ의 파라미터 개수|

                --- [패턴 1] 단순 키워드 (인자 없음, N = 0)
                if N == 0 and prems == empty:
                    => op sanitize(mixop) : -> WasmTerminal [ctor] .
                       eq is-type(sanitize(mixop), Type_id) = true .

                --- [패턴 2] 인자 포함 (Data-carrying, N > 0)
                else if N > 0 and prems == empty and 옵셔널 아님:
                    => op sanitize(mixop) _^N : WasmTerminal^N -> WasmTerminal [ctor] .
                       eq is-type(sanitize(mixop) V_1 ... V_N, Type_id)
                          = is-type(V_1, S_1) and ... and is-type(V_N, S_N) .

                --- [패턴 3] 옵셔널 파라미터 (IterT(_, Opt) 포함)
                --- 옵셔널 인덱스마다 eps 대입 버전 방정식 추가

                --- [패턴 4] 전제조건 있음 (prems ≠ ∅)
                else if prems != empty:
                    => ceq is-type(i_var, Type_id) = true if binder_conds and prem_conds .

        if deftyp == AliasT(typ):
            => eq is-type(T/TS, Type_id) = is-type(T, translate_typ(typ)) .

        if deftyp == StructT(fields):
            => eq is-type({item('F1,V1); ... ; item('Fn,Vn)}, Type_id)
                  = is-type(V1, S1) and ... and is-type(Vn, Sn) .
```

### 1.3 구체적 예제

**패턴 1: 단순 키워드 (numtype)**

- SpecTec 원본: `syntax numtype = | I32 | I64 | F32 | F64`
- Maude 변환:
  ```
  op numtype : -> WasmType [ctor] .
  op I32 : -> WasmTerminal [ctor] .
  eq is-type(I32, numtype) = true .
  op I64 : -> WasmTerminal [ctor] .
  eq is-type(I64, numtype) = true .
  ...
  ```

**패턴 2: 인자 포함 (CONST)**

- SpecTec 원본: `syntax instr = | CONST numtype num_(numtype)`
- Maude 변환:
  ```
  op CONST _ _ : WasmTerminal WasmTerminal -> WasmTerminal [ctor] .
  eq is-type(CONST NT C, instr) = is-type(NT, numtype) and is-type(C, num) .
  ```

**패턴 2: 파라미터 타입 (binop)**

- SpecTec 원본: `syntax binop_(Inn) = | ADD | SUB | MUL | ...`
- Maude 변환:
  ```
  op binop : WasmTerminal -> WasmType [ctor] .
  op ADD : -> WasmTerminal [ctor] .
  eq is-type(ADD, binop(NT)) = is-type(NT, Inn) .
  op SUB : -> WasmTerminal [ctor] .
  eq is-type(SUB, binop(NT)) = is-type(NT, Inn) .
  ...
  ```

**AliasT**

- SpecTec 원본: `syntax consttype = | numtype | vectype`
- Maude 변환:
  ```
  eq is-type(T, consttype) = is-type(T, numtype) .
  eq is-type(T, consttype) = is-type(T, vectype) .
  ```

**StructT**

- SpecTec 원본: `syntax memarg = {ALIGN u32, OFFSET u32}`
- Maude 변환:
  ```
  eq is-type({item('ALIGN, V1) ; item('OFFSET, V2)}, memarg)
     = is-type(V1, u32) and is-type(V2, u32) .
  ```

---

## 2. translate_decd (DecD)

`def` 함수 정의를 Maude `op` 선언과 `eq`/`ceq` 방정식으로 변환한다.

### 2.1 요약 표

| 패턴명 | 조건 | 변환 방식 |
|--------|------|------------|
| op 선언 | 항상 | `op $sanitize(id) : sort_1 ... sort_n -> ret_sort .` |
| eq | prems=∅, binder_conds=∅ | `eq $fn(LHS) = RHS .` |
| ceq | prems≠∅ 또는 binder_conds≠∅ | `ceq $fn(LHS) = RHS if conds .` |
| owise | ElsePr 존재 | `[owise]` 속성 추가 |
| 변수 선언 | LHS에 등장 | `vars V_1 ... V_k : WasmTerminal .` |
| 스콜렘화 | RHS/COND에만 등장 | `op V : -> WasmTerminal .` |

### 2.2 실전 압축 수도코드

```
[[ DecD(id, params, result_typ, insts) ]] =>
    let fn = "$" ^ sanitize(id)
    op fn : sort_1 ... sort_n -> ret_sort .

    insts 내의 각 DefD(binders, lhs_args, rhs, prems)에 대해:
        vm = binder_to_var_map(prefix, eq_idx, binders)
        LHS = fn(translate_exp(lhs_args[0]), ..., translate_exp(lhs_args[n]))
        RHS = translate_exp(rhs, vm)
        COND = binder_type_conds(binders) and translate_prem(prems)

        bound = vars in LHS  => vars 선언
        free  = vars only in RHS/COND  => op 상수 선언 (스콜렘화)

        if COND == empty: eq LHS = RHS [owise?] .
        else: ceq LHS = RHS if COND [owise?] .
```

### 2.3 구체적 예제

**단순 eq ($const)**

- SpecTec 원본: `def $const(numtype, c) = (CONST numtype c)`
- Maude 변환:
  ```
  op $const : WasmTerminal WasmTerminal -> WasmTerminal .
  eq $const ( NT , C ) = CONST NT C .
  ```

**ceq ($iadd)**

- SpecTec 원본: `def $iadd(N : N, iN_1 : iN(N), iN_2 : iN(N)) = (i_1 + i_2) mod (2 ^ N)`
- Maude 변환:
  ```
  op $iadd : WasmTerminal WasmTerminal WasmTerminal -> WasmTerminal .
  vars IADD0-WN IADD0-IN1 IADD0-IN2 : WasmTerminal .
  ceq $iadd ( IADD0-WN , IADD0-IN1 , IADD0-IN2 )
     = ( ( IADD0-IN1 + IADD0-IN2 ) rem ( 2 ^ IADD0-WN ) )
     if is-type ( IADD0-WN , w-N )
    and is-type ( IADD0-IN1 , iN ( IADD0-WN ) )
    and is-type ( IADD0-IN2 , iN ( IADD0-WN ) ) .
  ```

**ceq with premise ($binop dispatch)**

- SpecTec 원본: `def $binop(Inn, ADD, iN_1, iN_2) = $iadd($size(Inn), iN_1, iN_2)`
- Maude 변환:
  ```
  ceq $binop ( BINOP0-INN , ADD , BINOP0-IN1 , BINOP0-IN2 )
     = $iadd ( $sizenn ( BINOP0-INN ) , BINOP0-IN1 , BINOP0-IN2 )
     if is-type ( BINOP0-INN , Inn )
    and is-type ( BINOP0-IN1 , num ( BINOP0-INN ) )
    and is-type ( BINOP0-IN2 , num ( BINOP0-INN ) ) .
  ```

---

## 3. translate_reld (RelD)

`rule` 관계 정의를 Maude `op` 선언과 `eq`/`ceq` 방정식으로 변환한다.

### 3.1 요약 표

| 패턴명 | 조건 | 변환 방식 |
|--------|------|------------|
| op 선언 | 항상 | `op sanitize(rel_name) : WasmTerminal^arity -> Bool .` |
| eq | prems=∅, binder_conds=∅ | `eq rel_name(conclusion) = true .` |
| ceq | prems≠∅ 또는 binder_conds≠∅ | `ceq rel_name(conclusion) = true if conds .` |

### 3.2 실전 압축 수도코드

```
[[ RelD(id, _, _, rules) ]] =>
    op sanitize(id) : WasmTerminal^arity -> Bool .

    rules 내의 각 RuleD(case_id, binders, _, conclusion, prems)에 대해:
        vm = binder_to_var_map(rel_prefix-case_prefix, rule_idx, binders)
        ARGS = translate_exp(conclusion, vm)   --- TupE면 콤마 연결
        COND = binder_type_conds and translate_prem(prems)

        bound = vars in conclusion  => vars 선언
        free  = vars only in prems  => op 상수 선언

        if COND == empty: eq rel_name(ARGS) = true .
        else: ceq rel_name(ARGS) = true if COND .
```

### 3.3 구체적 예제

**단순 eq (Step_pure/nop)**

- SpecTec 원본: `rule Step_pure/nop: NOP ~> eps`
- Maude 변환:
  ```
  op Step-pure : WasmTerminal WasmTerminal -> Bool .
  eq Step-pure ( NOP , eps ) = true .
  ```

**ceq (Step_pure/binop-val)**

- SpecTec 원본: `rule Step_pure/binop-val: (CONST nt c_1)(CONST nt c_2)(BINOP nt binop) ~> (CONST nt c) if c <- $binop(nt, binop, c_1, c_2)`
- Maude 변환:
  ```
  ceq Step-pure (
        CONST NT CN1  CONST NT CN2  BINOP NT BINOP ,
        CONST NT WC
      ) = true
    if is-type ( NT , numtype )
   and is-type ( CN1 , num ( NT ) )
   and is-type ( CN2 , num ( NT ) )
   and is-type ( BINOP , binop ( NT ) )
   and is-type ( WC , num ( NT ) )
   and ( WC <- $binop ( NT , BINOP , CN1 , CN2 ) ) .
  ```

---

## 4. translate_exp (표현식 변환)

SpecTec 표현식을 Maude 텍스트로 변환한다. `ctx ∈ {BoolCtx, TermCtx}`에 따라 Boolean 래핑이 달라진다.

### 4.1 요약 표

| 패턴명 | AST 노드 | 변환 방식 |
|--------|----------|------------|
| VarE | 변수 | vm 조회 또는 sanitize(id) 또는 to_var_name(id) |
| NumE | 숫자 | 정수/유리수/실수 리터럴 |
| BoolE | 불리언 | wrap_bool(ctx, "true"/"false") |
| CaseE | 믹스픽스 | sections와 args 교차 배치 |
| CallE | 함수호출 | `$sanitize(id)(arg1, arg2, ...)` |
| BinE | 이항연산 | `(e1 op e2)` |
| CmpE | 비교 | wrap_bool(ctx, (e1 op e2)) |
| StrE | 레코드 | `{item('F1,v1); item('F2,v2); ...}` |
| DotE | 필드접근 | `value('ATOM, e)` |
| TupE/ListE | 튜플/리스트 | 공백 연결 (빈 경우 eps) |
| IfE | 조건 | `if c then e1 else e2 fi` |
| MemE | 멤버십 | wrap_bool(ctx, (e1 <- e2)) |
| CompE | 병합 | `merge(e1, e2)` |
| CatE | 연결 | `e1 e2` (공백) |
| LenE | 길이 | `len(e)` |
| IdxE | 인덱스 | `index(e1, e2)` |
| SliceE | 슬라이스 | `slice(e1, e2, e3)` |
| UpdE | 업데이트 | `(e1 [path <- e2])` |
| ExtE | 확장 | `(e1 [path =++ e2])` |
| IterE | 반복 변수 | vm에서 suffix(*/+/?) 조회 |
| OptE None | 빈 옵션 | `eps` |

### 4.2 실전 압축 수도코드

```
[[ translate_exp(ctx, e, vm) ]] =>
    match e:
        VarE id:
            vm 조회 → mapped
            else if "true"/"false" → wrap_bool(ctx, ...)
            else if token-like → sanitize(id)
            else if suffixed → resolve_suffixed → mapped
            else → to_var_name(id)

        NumE n: Z.to_string(n) 또는 "num/den" 또는 "%.17g"
        BoolE b: wrap_bool(ctx, "true"/"false")
        TextE s: "\"" ^ s ^ "\""

        CaseE(mixop, inner):
            if mixop = "$" or "%" or "" → translate_exp(inner)
            else: sections와 args 교차 배치 (sect1 V1 sect2 V2 ...)

        CallE(id, args): $sanitize(id)(translate_arg(args))

        BinE(op, _, e1, e2): (translate_exp(e1) op_str translate_exp(e2))
        CmpE(op, _, e1, e2): wrap_bool(ctx, (e1 op e2))
        UnE(NotOp, _, e1): wrap_bool(ctx, not(e1))
        UnE(MinusOp, _, e1): - ( e1 )
        UnE(PlusOp, _, e1): e1

        StrE fields: {item('F1,v1) ; item('F2,v2) ; ...}
        DotE(e, atom): value('ATOM, translate_exp(e))

        TupE [] | ListE []: eps
        TupE [e1]: translate_exp(e1)
        TupE el | ListE el: translate_exp(e1) " " ... " " translate_exp(en)

        IfE(c,e1,e2): if translate_exp(BoolCtx,c) then translate_exp(e1) else translate_exp(e2) fi
        MemE(e1,e2): wrap_bool(ctx, (e1 <- e2))
        CompE(e1,e2): merge ( e1 , e2 )
        CatE(e1,e2): e1 e2
        LenE(e1): len ( e1 )
        IdxE(e1,e2): index ( e1 , e2 )
        SliceE(e1,e2,e3): slice ( e1 , e2 , e3 )
        UpdE(e1,path,e2): ( e1 [ path <- e2 ] )
        ExtE(e1,path,e2): ( e1 [ path =++ e2 ] )

        IterE(VarE id, (List|List1|Opt, _)): vm[id^*|^+|^?] 또는 to_var_name(id+suffix)
        OptE None: eps
        OptE Some e1 | TheE e1 | LiftE e1: translate_exp(e1)
        CvtE | SubE | ProjE | UncaseE: translate_exp(inner)
```

### 4.3 구체적 예제

**VarE**

- SpecTec 원본: `VarE "nt"` (vm: nt → NT)
- Maude 변환: `NT`

**CaseE (믹스픽스)**

- SpecTec 원본: `CaseE(CONST, TupE[VarE nt, VarE c])`
- Maude 변환: `CONST NT C`

**CallE**

- SpecTec 원본: `CallE("binop", [nt, binop, c1, c2])`
- Maude 변환: `$binop ( NT , BINOP , C1 , C2 )`

**StrE**

- SpecTec 원본: `StrE [("ALIGN", e1), ("OFFSET", e2)]`
- Maude 변환: `{item('ALIGN, V1) ; item('OFFSET, V2)}`

**BinE**

- SpecTec 원본: `BinE(AddOp, _, e1, e2)`
- Maude 변환: `( V1 + V2 )`

**CmpE**

- SpecTec 원본: `CmpE(EqOp, _, e1, e2)` (TermCtx)
- Maude 변환: `w-bool ( ( V1 == V2 ) )`

**IfE**

- SpecTec 원본: `IfE(cond, e1, e2)`
- Maude 변환: `if COND then E1 else E2 fi`

**MemE (전제조건)**

- SpecTec 원본: `MemE(VarE "c", CallE("binop", [...]))`
- Maude 변환: `( WC <- $binop ( NT , BINOP , CN1 , CN2 ) )`

---

## 5. 보조 변환 규칙

### 5.1 translate_prem (전제조건)

| Prem 노드 | 변환 |
|-----------|------|
| IfPr e | translate_exp(BoolCtx, e) |
| RulePr(id, _, e) | sanitize(id)(translate_exp(e)) |
| LetPr(e1, e2, _) | (e1 == e2) |
| ElsePr | owise (속성으로 처리) |
| IterPr(inner, _) | translate_prem(inner) |
| NegPr inner | translate_prem(inner) |

### 5.2 translate_arg (인자)

| Arg 노드 | 변환 |
|----------|------|
| ExpA e | translate_exp(TermCtx, e) |
| TypA t | translate_typ(t) |
| DefA _ | eps |
| GramA _ | eps |

### 5.3 translate_typ (타입)

| Typ 노드 | 변환 |
|----------|------|
| VarT(id, []) | sanitize(id) 또는 vm[id] |
| VarT(id, args) | sanitize(id)(arg1, arg2, ...) |
| IterT(inner, _) | translate_typ(inner) |
| 기타 | WasmType |

### 5.4 sanitize (식별자 정규화)

| 조건 | 변환 |
|------|------|
| "_" | any |
| 단일문자, 비알파시작, Maude 키워드 | w- prefix |
| `.` `_` `'` `*` `+` `?` | `-` |
| `-digit` 시퀀스 | Ndigit |
| 후행 하이픈 | 제거 |

**예**: `numtype_2` → `numtypeN2`, `$` → `w-$`

### 5.5 wrap_bool (Boolean 래핑)

```
wrap_bool(BoolCtx, s) = s
wrap_bool(TermCtx, s) = w-bool ( s )
```

Boolean 맥락(BoolCtx): IfPr, and/or/implies, not, Bool 반환 함수 RHS  
Term 맥락(TermCtx): 그 외

---

## 6. 변수 명명 규칙

**DecD**: `PREFIX<eq_idx>-SANITIZE(raw_v)`  
예: `$iadd`의 binder `iN_1` → `IADD0-IN1`

**RelD**: `REL_PREFIX-CASE_PREFIX<rule_idx>-SANITIZE(raw_v)`  
예: `Step_pure/binop-val`의 binder `nt` → `STEP-PURE-BINOP-VAL48-NT`

**to_var_name**: sanitize 후 대문자화. 예: `nt` → `NT`
