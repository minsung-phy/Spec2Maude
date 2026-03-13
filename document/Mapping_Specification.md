# Formal Specification of WebAssembly Translation Mapping : SpecTec to Maude

<div align="right">
  <strong>포항공과대학교 SVLab 이민성</strong><br>
  <strong>2026.03.14</strong>
</div>

## 1. Pipeline
본 문서는 WebAssembly SpecTec의 AST를 입력받아, Maude의 Algebraic Specification으로 변환하는 알고리즘의 형식적 정의를 다룬다.

```text
SpecTec AST
-> [translator.ml] 
-> .maude
```


## 2. Pre-defined Infrastructure
변환 로직에서 사용하는 기본 타입과 유틸리티 함수의 정의이다.

```text
(* Sorts *)
sort WasmTerminal .  *** 원자값, 생성자, 단일 명령어
sort WasmTerminals . *** 구문들의 리스트 (e.g., instr*)
sort WasmType .      *** 타입 카테고리 식별자

(* Core interface *)
op typecheck : WasmTerminal WasmType -> Bool .
op typecheck : WasmTerminals WasmType -> Bool .

(* Naming Conventions *)
sanitize(name)   (* '_' → '-',  trailing '%' 제거 *)
to_var_name(name)  (* binder → Maude variable  e.g. inn → INN *)
is_plural(type)  (* AST 순회 중 리스트(*, +) 기호나 의미론적 복수형(expr) 식별 *)
```


## 3. Translate TypD (Syntax Definition)
SpecTec의 syntax 정의(TypD)를 Maude의 op 선언 및 typecheck equation으로 변환하는 재귀 알고리즘이다.

**3.1 Definition & Instance Level**
```text
// 1. 메인 정의 변환
translate_definition : Def -> String
translate_definition(TypD(id, params, insts)) = 
    let name = sanitize(id)
    let sig_types = concat(map(fun _ -> "WasmTerminal", params))
    let op_decl = "  op " + name + " : " + sig_types + " -> WasmType [ctor] .\n"
    op_decl + translate_instances(id, params, insts)

// 2. 인스턴스 리스트 재귀 처리
translate_instances : ID -> Params -> List(Inst) -> String
translate_instances(id, ps, inst :: rest) = 
    translate_instance(id, ps, inst) + "\n" + translate_instances(id, ps, rest)
translate_instances(id, ps, nil) = ""

// 3. 단일 인스턴스 변환
translate_instance : ID -> Params -> Inst -> String

// [Case A] VariantT (합타입, 생성자, 범위 제약 등)
translate_instance(id, ps, InstD(binders, args, VariantT(cases))) = 
    let v_map = build_v_map(binders)
    let binder_conds = build_binder_conds(binders)
    let full_type_name = build_full_type_name(id, args, v_map)
    translate_cases(cases, v_map, binder_conds, full_type_name)

// [Case B] AliasT (단순 타입 위임)
translate_instance(id, ps, InstD(binders, args, AliasT(typ))) = 
    let v_map = build_v_map(binders)
    let binder_conds = build_binder_conds(binders)
    let full_type_name = build_full_type_name(id, args, v_map)
    
    // 1. 우항(RHS) 알맹이 타입 추출 (IterT 껍데기 제거)
    let rhs_body = match typ with
                   | IterT(inner, _) -> translate_typ(inner, v_map)
                   | _               -> translate_typ(typ, v_map)
                   
    // 2. [하드코딩] expr 식별자를 위한 변수명 하드코딩
    let var_name = if sanitize(id) == "expr" then "INSTRS" else "T"
    
    // 3. 위임 조건문 조립 및 등식 생성
    let p_cond = "typecheck(" + var_name + ", " + rhs_body + ")"
    let cond_str = concat_with_and(binder_conds + [p_cond])
    
    "  eq typecheck(" + var_name + ", " + full_type_name + ") = " + cond_str + " ."
```

**3.2 Case & Rule Generation**
```text
// 4. Variant 케이스 리스트 재귀 처리
translate_cases : List(Case) -> Context -> List(Cond) -> String -> String
translate_cases(c :: rest, v_map, binder_conds, full_type) = 
    translate_case(c, v_map, binder_conds, full_type) + "\n" + translate_cases(rest, v_map, binder_conds, full_type)
translate_cases(nil, _, _, _) = ""

// 5. 개별 케이스 번역 로직
translate_case : Case -> Context -> List(Cond) -> String -> String
translate_case((mixop_val, (_, case_typ, prems), _), v_map, binder_conds, full_type) = 
    let cons_name = extract_cons_name(mixop_val)
    
    if length(prems) > 0 then
        generate_ceq_rule(cons_name, v_map, binder_conds, full_type, prems)
    else
        let (params, _) = collect_params(v_map, case_typ, false)
        let lhs_usage = format_lhs(cons_name, params)
        let op_decl_name = format_op(cons_name, params)
        
        let main_rule = generate_main_rule(cons_name, op_decl_name, lhs_usage, full_type, params, binder_conds)
        
        // [하드코딩] 인자가 여러 개인 eps가 있으면 수정해야 함
        let empty_rule = 
            if length(params) == 1 then
                match find_iter(case_typ) with
                | Some(sym) -> "\n  eq typecheck(" + cons_name + " " + sym + ", " + full_type + ") = true ."
                | None -> ""
            else ""
            
        main_rule + empty_rule
```

**3.3 Structural Decomposition (Recursive Helpers)**
```text
// 인자 추출 및 변수명 생성
collect_params : Context -> Type -> Bool -> (List(Param) * Context)
collect_params(C, VarT(tid, _), isL) = 
    let v_base = to_var_name(tid)
    let indexed_name = if isL then v_base + "*" else v_base + get_count(v_base)
    let ms = if (isL or is_plural_type(tid)) then "WasmTerminals" else "WasmTerminal"
    ([(indexed_name, translate_typ(VarT), ms)], C + {tid -> indexed_name})
collect_params(C, IterT(inner, iter), _) = 
    collect_params(C, inner, (iter == List or iter == List1))
collect_params(C, TupT(fields), isL) = 
    collect_params_list(C, fields, isL)
collect_params(C, _, _) = 
    ([], C)

// 튜플 내부 필드 순회
collect_params_list : Context -> List(Field) -> Bool -> (List(Param) * Context)
collect_params_list(C, f :: rest, isL) = 
    let (p1, c1) = collect_params(C, f, isL)
    let (p2, c2) = collect_params_list(c1, rest, isL)
    (p1 + p2, c2)
collect_params_list(C, nil, _) = 
    ([], C)

// Opt(?) 타입 탐색
find_iter : Type -> Option(String)
find_iter(IterT(_, Opt)) = Some("eps")
find_iter(TupT(fields))  = find_iter_list(fields)
find_iter(_)             = None

// 튜플 내부 Opt 탐색
find_iter_list : List(Field) -> Option(String)
find_iter_list(f :: rest) = 
    match find_iter(f) with
    | Some(sym) -> Some(sym)
    | None -> find_iter_list(rest)
find_iter_list(nil) = None
```


## 4. Translate DecD (Function Definition)
(작성 예정)


## 5. Translate Rule (Inference Rule)
(작성 예정)


## 6. Representative Translation Examples
알고리즘의 실제 동작을 증명하기 위한 종단간(End-to-End) 실행 추적 예시이다.

**6.1 Basic Mapping: Alias Type**
단순 위임 패턴(AliasT)의 변환 과정이다.

1. Spectec Source
```text
syntax idx = u32
```

2. Internal AST (IL)
```text
TypD("idx", 
     [], 
     [ InstD([], [], AliasT(VarT(id "u32", []))) ]
    )
```

3. Execution Trace
```text
[Step 1] translate_definition(TypD("idx", [], insts))
    let name = "idx"
    let sig_types = ""
    let op_decl = "op idx : -> WasmType [ctor] .\n"

    emit: op_decl + translate_instances("idx", [], insts)

[Step 2] translate_instances("idx", [], [inst])
    emit: translate_instance("idx", [], inst) + "\n"

[Step 3] translate_instance("idx", [], InstD([], [], AliasT(VarT("u32", []))))
    // 1. Context 초기화
    let v_map = []
    let binder_conds = []
    let full_type_name = "idx"
    
    // 2. AliasT 매핑 로직
    let rhs_body = "u32"
    let var_name = "T"
    let p_cond = "typecheck(T, u32)"
    let cond_str = "typecheck(T, u32)"
  
    emit: "eq typecheck(T, idx) = typecheck(T, u32) ."
```

4. Result
```text
op idx : -> WasmType [ctor] .
eq typecheck(T, idx) = typecheck(T, u32) .
```

**6.2 Advanced Mapping: Variant with Epsilon**
생성자 선언, 변수명 자동 치환(to_var_name), 그리고 옵셔널(?) 타입에 대한 기저 사례(eps) 생성 과정이 모두 포함된 복합 패턴이다.

1. SpecTec Source
```text
syntax blocktype =
  | _RESULT valtype?
  | _IDX typeidx
```

2. Internal AST (IL)
```text
TypD ("blocktype", 
      [], 
      [InstD (
        [], [],
        VariantT [
          (["_RESULT%"], ([], IterT (VarT ("valtype", []), Opt), []), []);
          (["_IDX%"], ([], VarT ("typeidx", []), []), [])
        ]
        )
      ]
    )
```

3. Execution Trace
```text
[Step 1] translate_definition(TypD("blocktype", [], insts))
    let name = blocktype
    let sig_types = ""
    let op_decl = "op blocktype : -> WasmType [ctor] .\n"

    emit: op_decl + translate_instances("blocktype", [], insts)

[Step 2] translate_instances("blocktype", [], [inst])
    emit: translate_instance("blocktype", [], inst) + "\n"

[Step 3] translate_instance("blocktype", [], InstD(..., VariantT(cases)))
    // 1. Context 초기화 (binders가 없으므로 빈 상태)
    let v_map = []
    let binder_conds = []
    let full_type_name = "blocktype"
    
    emit: translate_cases(cases, v_map, binder_conds, "blocktype")

[Step 4] translate_cases -> Case 1: _RESULT valtype? 
    // ast: (["_RESULT%"], IterT(VarT("valtype"), Opt))
    let cons_name = "-RESULT" // sanitize("_RESULT%")
  
    // 1. 인자 추출 (collect_params)
    let params = [("VALTYPE", "valtype", "WasmTerminal")]
    let lhs_usage = "-RESULT VALTYPE"
    let op_decl_name = "-RESULT _"
  
    // 2. 일반 규칙 생성 (generate_main_rule)
    let main_rule = 
        "  op _RESULT _ : WasmTerminal -> WasmTerminal [ctor] .\n" +
        "  var VALTYPE : WasmTerminal .\n" +
        "  eq typecheck(-RESULT VALTYPE, blocktype) = typecheck(VALTYPE, valtype) ."
        
    // 3. 기저 사례 생성 (find_iter에서 Opt(?) 발견)
    let empty_rule = 
        "\n  eq typecheck(-RESULT eps, blocktype) = true ."
        
    emit: main_rule + empty_rule

[Step 5] translate_cases -> Case 2: _IDX typeidx
    // ast: (["_IDX%"], VarT("typeidx"))
    let cons_name = "-IDX" // sanitize("_IDX%")
    
    // 1. 인자 추출 (collect_params)
    let params = [("TYPEIDX", "typeidx", "WasmTerminal")]
    let lhs_usage = "-IDX TYPEIDX"
    let op_decl_name = "-IDX _"
    
    // 2. 일반 규칙 생성 (generate_main_rule)
    let main_rule = 
        "  op -IDX _ : WasmTerminal -> WasmTerminal [ctor] .\n" +
        "  var TYPEIDX : WasmTerminal .\n" +
        "  eq typecheck(-IDX TYPEIDX, blocktype) = typecheck(TYPEIDX, typeidx) ."
        
    // 3. 기저 사례 생성 (find_iter에서 Opt를 찾지 못함 -> None 반환)
    let empty_rule = ""
  
    emit: main_rule
```

4. Result
```text
op blocktype : -> WasmType .

op -RESULT _ : WasmTerminal -> WasmTerminal [ctor] .
var VALTYPE : WasmTerminal .
eq typecheck(-RESULT VALTYPE, blocktype) = typecheck(VALTYPE, valtype) .
eq typecheck(-RESULT eps, blocktype) = true .

op -IDX _ : WasmTerminal -> WasmTerminal .
var TYPEIDX : WasmTerminal .
eq typecheck(-IDX TYPEIDX, blocktype) = typecheck(TYPEIDX, typeidx) .
```

## 7. Appendix : Helper Functions
변환 로직의 문자열 포맷팅 및 컨텍스트 관리를 위한 보조 함수 정의이다.

**7.1 Formatting Helpers**
```text
format_lhs : Name -> List(Param) -> String
format_lhs("->-", p0 :: p1 :: p2 :: nil) = p0 + " ->- " + p1 + " " + p2   // 하드코딩 분기
format_lhs("", params)                   = concat_with_space(params)      // Juxtaposition
format_lhs(name, params)                 = name + " " + concat_with_space(params)

format_op : Name -> List(Param) -> String
format_op("->-", p0 :: p1 :: p2 :: nil) = "_ ->- _ _"
format_op(name, params)                 = name + build_placeholders(params)

build_placeholders : List(Param) -> String
build_placeholders(nil) = ""
build_placeholders(p :: rest) = " _" + build_placeholders(rest)
```

**7.2 Mapping Helpers**
```text
// 1. 바인더(Binder)에서 변수명 매핑(Context) 추출
build_v_map : List(Binder) -> Context
build_v_map(ExpB(id, _) :: rest) = {id -> to_var_name(id)} U build_v_map(rest)
build_v_map(_ :: rest)           = build_v_map(rest)
build_v_map(nil)                 = empty_context

// 2. 바인더(Binder)에서 검증 조건(typecheck) 문자열 생성
build_binder_conds : List(Binder) -> List(Cond)
build_binder_conds(ExpB(id, _) :: rest) = 
    "typecheck(" + to_var_name(id) + ", " + sanitize(id) + ")" :: build_binder_conds(rest)
build_binder_conds(_ :: rest) = build_binder_conds(rest)
build_binder_conds(nil) = nil

// 3. 전체 타입 이름 포맷팅 (예: num-(INN))
build_full_type_name : ID -> List(Arg) -> Context -> String
build_full_type_name(id, args, v_map) = 
    let name = sanitize(id)
    let args_str = concat_with_comma(map(fun a -> translate_arg(a, v_map), args))
    if args_str == "" then name else name + "(" + args_str + ")"

// 4. Mixfix AST 노드에서 생성자 이름 추출
extract_cons_name : MixopVal -> Name
extract_cons_name(mixop_val) = 
    let flattened = flatten(mixop_val)
    if length(flattened) > 0 then sanitize(name_of_atom(head(flattened))) else ""

// 5. 조건부 등식(ceq) 룰 생성
generate_ceq_rule : Name -> Context -> List(Cond) -> String -> List(Premise) -> String
generate_ceq_rule(cons_name, v_map, binder_conds, full_type, prems) = 
    let conditions = map(fun (IfPr(e)) -> translate_exp(e, v_map), prems)
    let cond_str = concat_with_and(binder_conds + conditions)
    let var_name = "N_" + uppercase(cons_name)
    let var_decl = "  var " + var_name + " : Nat ."
    var_decl + "\n  ceq typecheck(i, " + full_type + ") = true \n   if " + cond_str + " ."

// 6. 메인 등식(eq) 룰 생성
generate_main_rule : Name -> Name -> String -> String -> List(Param) -> List(Cond) -> String
generate_main_rule(cons_name, op_decl_name, lhs_usage, full_type, params, binder_conds) = 
    let p_sorts = concat_with_space(map(fun (_, _, ms) -> ms, params))
    let v_decl = concat_with_newline(map(fun (v, _, ms) -> "  var " + v + " : " + ms + " .", params))
    let p_conds = map(fun (v, s, _) -> "typecheck(" + v + ", " + s + ")", params)
    let final_rhs = concat_with_and_or_true(binder_conds + p_conds)
    
    if cons_name == "" then
        "\n" + v_decl + "  eq typecheck(" + lhs_usage + ", " + full_type + ") = " + final_rhs + " ."
    else
        "  op " + op_decl_name + " : " + p_sorts + " -> WasmTerminal [ctor] .\n" + 
        v_decl + "  eq typecheck(" + lhs_usage + ", " + full_type + ") = " + final_rhs + " ."
```

**7.3 AST Node Translation Helpers**
```text
// 이 함수들은 TypD, DecD, Rule 변환 전반에서 식(Exp), 인자(Arg), 타입(Typ) AST 노드를 
// Maude의 문자열(String) 포맷으로 직렬화(Serialization)하는 역할을 수행한다.

// 1. 타입 번역기
translate_typ : Type -> Context -> String
translate_typ(VarT(id, args), v_map) = 
    let base_name = lookup_or_default(id, v_map, sanitize(id))
    if empty(args) then 
        base_name 
    else 
        base_name + "(" + concat_with_comma(map(fun a -> translate_arg(a, v_map), args)) + ")"
translate_typ(IterT(inner, _), v_map) = translate_typ(inner, v_map)
translate_typ(_, _) = "WasmType"

// 2. 인자 번역기
translate_arg : Arg -> Context -> String
translate_arg(ExpA(e), v_map) = translate_exp(e, v_map)
translate_arg(TypA(t), v_map) = translate_typ(t, v_map)
translate_arg(_, _) = "0"

// 3. 수식 번역기 (수학 연산 및 변수 평가)
translate_exp : Exp -> Context -> String
translate_exp(VarE(id), v_map) = 
    // ADD, SUB 등 하드코딩된 상수는 그대로 유지, 그 외는 v_map 매핑 또는 대문자화
    if is_constant(id) then id else lookup_or_default(id, v_map, uppercase(id))

translate_exp(NumE(n), _) = to_string(n)

translate_exp(UnE(op, e), v_map) = 
    let op_str = translate_unop(op)
    op_str + "(" + translate_exp(e, v_map) + ")"

translate_exp(BinE(op, e1, e2), v_map) = 
    let op_str = translate_binop(op) // e.g., AddOp -> "+", ModOp -> "rem"
    "(" + translate_exp(e1, v_map) + " " + op_str + " " + translate_exp(e2, v_map) + ")"

translate_exp(CallE(id, args), v_map) = 
    let fname = sanitize(id)
    let final_name = if starts_with(fname, "$") then fname else "$" + fname
    let arg_strs = concat_with_comma(map(fun a -> translate_arg(a, v_map), args))
    final_name + "(" + arg_strs + ")"

translate_exp(ListE(el), v_map) = 
    concat_with_space(map(fun e -> translate_exp(e, v_map), el))

// 껍데기(Proj, Uncase)는 벗겨내고 내부 알맹이만 번역
translate_exp(ProjE(e, _), v_map)   = translate_exp(e, v_map)
translate_exp(UncaseE(e, _), v_map) = translate_exp(e, v_map)

translate_exp(_, _) = "UNKNOWN_EXP"
```