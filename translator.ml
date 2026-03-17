(* Spec2Maude: SpecTec AST → Maude Algebraic Specification Translator *)

open Util.Source
open Il.Ast

let header =
  "load dsl/pretype \n\n" ^
  "mod SPECTEC-CORE is\n" ^
  "  inc DSL-RECORD .\n\n" ^
  "  --- Base Sort subsumptions\n" ^
  "  subsort Int < WasmTerminal .\n" ^
  "  subsort Nat < WasmTerminal .\n" ^
  "  subsort Bool < WasmTerminal .\n\n" ^
  "  --- Additional utility ops\n" ^
  "  op slice : WasmTerminals WasmTerminal WasmTerminal -> WasmTerminals .\n" ^
  "  op _<-_ : WasmTerminal WasmTerminals -> Bool .\n\n" ^
  "  --- Common variables\n" ^
  "  var I : Int .\n" ^
  "  var T : WasmTerminal .\n" ^
  "  var TS : WasmTerminals .\n"

let footer =
  "\nendm\n"

(* ------------------- Helper ------------------- *)

(* 이름에서 _를 -로 바꾸고 끝에 %를 제거하는 함수 *)
let sanitize name =
  let s = String.map (fun c -> if c = '_' then '-' else c) name in
  if String.length s > 0 && s.[String.length s - 1] = '%' then
    String.sub s 0 (String.length s - 1)
  else s

(* 변수명을 대문자로 변환 (Inn -> INN) *)
let to_var_name name = String.uppercase_ascii (sanitize name)

(* Type Environment: AliasT(IterT(_, List|List1))인 타입을 구조적으로 탐지하기 위한 환경 *)
let plural_types : (string, bool) Hashtbl.t = Hashtbl.create 32

let build_type_env (defs : def list) =
  let rec scan d = match d.it with
    | RecD ds -> List.iter scan ds
    | TypD (id, _, insts) ->
        List.iter (fun inst -> match inst.it with
          | InstD (_, _, deftyp) -> (match deftyp.it with
            | AliasT typ -> (match typ.it with
              | IterT (_, (List | List1)) -> Hashtbl.replace plural_types id.it true
              | _ -> ())
            | _ -> ())
        ) insts
    | _ -> ()
  in
  List.iter scan defs

(* 구조적 판별: 하드코딩 없이 build_type_env에서 수집된 정보 사용 *)
let is_plural_type (type_name : string) : bool =
  Hashtbl.mem plural_types type_name

(* --- Mixfix 일반화 헬퍼 (Rule V-M) --- *)

(* mixop에서 각 섹션의 atom 이름을 추출하여 sanitize된 문자열 리스트로 반환 *)
let mixop_sections (mixop_val : Xl.Mixop.mixop) : string list =
  List.map (fun atoms ->
    atoms |> List.map Xl.Atom.name |> String.concat "" |> sanitize
  ) mixop_val

(* 섹션과 변수를 교차 배치: section₀ var₀ section₁ var₁ ... sectionₙ *)
let interleave_lhs (sections : string list) (vars : string list) : string =
  let rec go secs vs = match secs, vs with
    | [], vs_rest -> vs_rest
    | s :: ss, v :: vs' ->
        (if s <> "" then [s; v] else [v]) @ go ss vs'
    | [s], [] -> if s <> "" then [s] else []
    | _ :: ss, [] -> go ss []
  in
  String.concat " " (go sections vars)

(* op 선언명 생성: section₀ _ section₁ _ ... sectionₙ *)
let interleave_op (sections : string list) (n_vars : int) : string =
  let rec go secs remaining = match secs, remaining with
    | [], n -> List.init n (fun _ -> "_")
    | s :: ss, n when n > 0 ->
        (if s <> "" then [s; "_"] else ["_"]) @ go ss (n - 1)
    | [s], 0 -> if s <> "" then [s] else []
    | _ :: ss, 0 -> go ss 0
    | _, _ -> []
  in
  String.concat " " (go sections n_vars)

(* --- eps 다중 인자 일반화 헬퍼 (Rule V-E) --- *)

(* 타입 구조를 재귀 순회하여 Opt가 위치한 인자 인덱스 목록을 반환 *)
let find_opt_param_indices (case_typ : typ) : int list =
  let idx = ref 0 in
  let result = ref [] in
  let rec scan t is_opt = match t.it with
    | VarT _ ->
        if is_opt then result := !idx :: !result;
        idx := !idx + 1
    | IterT (inner, Opt) ->
        scan inner true
    | IterT (inner, _) ->
        scan inner is_opt
    | TupT fields ->
        List.iter (fun (_, ft) -> scan ft is_opt) fields
    | _ -> ()
  in
  scan case_typ false;
  List.rev !result


(* 수식(Expression) 변환 함수: 연산자 이름을 그대로 사용함 *)
let rec translate_exp (e : exp) (v_map : (string * string) list) : string =
  match e.it with
  | VarE id -> 
      (try List.assoc id.it v_map 
       with Not_found -> 
         (* 상수(ADD, SUB, EQ, false, true 등)는 변환하지 않고 그대로 출력 / 얘네는 나중을 위해 고정된 상수라는 것을 알려주기 위해 써놓음 *)
         if id.it = "ADD" || id.it = "SUB" || id.it = "EQ" || id.it = "false" || id.it = "true" then id.it 
         else String.uppercase_ascii id.it)
  
  | CaseE (mixop, inner_exp) ->
      let op_name = 
        try List.flatten mixop |> List.map Xl.Atom.name |> String.concat "" 
        with _ -> "UNKNOWN_CASE"
      in
      (* $ 기호 또는 % 포맷팅 기호는 껍데기를 벗기고 내부 수식을 평가 *)
      if op_name = "$" || op_name = "%" || op_name = "" then translate_exp inner_exp v_map
      else op_name

  | NumE n -> 
      (match n with 
       | `Nat z | `Int z -> Z.to_string z 
       | `Rat q -> Z.to_string (Q.num q) ^ "/" ^ Z.to_string (Q.den q)
       | `Real r -> Printf.sprintf "%.17g" r)
       
  | CvtE (e1, _, _) -> translate_exp e1 v_map
  | SubE (e1, _, _) -> translate_exp e1 v_map
  
  (* AST의 투영(proj) 및 언케이스(uncase) 노드 처리 - 껍데기 벗기고 알맹이만 반환 *)
  | ProjE (e1, _) -> translate_exp e1 v_map
  | UncaseE (e1, _) -> translate_exp e1 v_map

  | UnE (op, _, e1) -> 
      let op_str = (match (op : unop) with `MinusOp -> "-" | `PlusOp -> "+" | `NotOp -> "not ") in
      if op_str = "-" then Printf.sprintf "- %s" (translate_exp e1 v_map)
      else Printf.sprintf "%s(%s)" op_str (translate_exp e1 v_map)
      
  | BinE (op, _, e1, e2) -> 
      let op_str = (match (op : binop) with 
        | `AddOp -> "+" | `SubOp -> "-" | `MulOp -> "*" | `DivOp -> "/" 
        | `ModOp -> "rem" (* % 에서 rem으로 변경 *)
        | `PowOp -> "^" | `AndOp -> "/\\" | `OrOp -> "\\/" 
        | `ImplOp -> "implies" | `EquivOp -> "==" 
      ) in
      Printf.sprintf "(%s %s %s)" (translate_exp e1 v_map) op_str (translate_exp e2 v_map)
  
  | CmpE (op, _, e1, e2) ->
      let op_str = (match (op : cmpop) with `LtOp -> "<" | `GtOp -> ">" | `LeOp -> "<=" | `GeOp -> ">=" | `EqOp -> "==" | `NeOp -> "=/=" ) in
      Printf.sprintf "(%s %s %s)" (translate_exp e1 v_map) op_str (translate_exp e2 v_map)

  | CallE (id, args) -> 
      let arg_strs = List.map (fun a -> translate_arg a v_map) args in
      let fname = sanitize id.it in
      if fname = "$" then String.concat ", " arg_strs
      else
        let final_name = if String.length fname > 0 && fname.[0] = '$' then fname else "$" ^ fname in
        Printf.sprintf "%s(%s)" final_name (String.concat ", " arg_strs)
  
  (* 괄호로 묶인 수식을 처리하기 위한 TupE 추가 *)
  | TupE [] -> ""
  | TupE [e1] -> translate_exp e1 v_map
  | TupE el -> "(" ^ String.concat ", " (List.map (fun x -> translate_exp x v_map) el) ^ ")"
  
  | ListE el -> String.concat " " (List.map (fun x -> translate_exp x v_map) el)
  (* --- 신규 exp' 분기들 (§6.2) --- *)

  | BoolE b -> if b then "true" else "false"
  | TextE s -> "\"" ^ s ^ "\""

  (* 레코드 리터럴: {item('FIELD, e) ; ...} *)
  | StrE fields ->
      let items = List.map (fun (atom, e1) ->
        let qid = "'" ^ String.uppercase_ascii (sanitize (Xl.Atom.name atom)) in
        Printf.sprintf "item(%s, %s)" qid (translate_exp e1 v_map)
      ) fields in
      "{" ^ String.concat " ; " items ^ "}"

  (* 레코드 필드 접근: value('FIELD, e) *)
  | DotE (e1, atom) ->
      let qid = "'" ^ String.uppercase_ascii (sanitize (Xl.Atom.name atom)) in
      Printf.sprintf "value(%s, %s)" qid (translate_exp e1 v_map)

  (* 레코드 합성: e1 ++ e2 *)
  | CompE (e1, e2) ->
      Printf.sprintf "%s ++ %s" (translate_exp e1 v_map) (translate_exp e2 v_map)

  (* 멤버십 검사: e1 <- e2 *)
  | MemE (e1, e2) ->
      Printf.sprintf "(%s <- %s)" (translate_exp e1 v_map) (translate_exp e2 v_map)

  (* 길이 연산: len(e) *)
  | LenE e1 ->
      Printf.sprintf "len(%s)" (translate_exp e1 v_map)

  (* 리스트 연결: e1 e2 (Maude의 WasmTerminals 결합은 juxtaposition) *)
  | CatE (e1, e2) ->
      Printf.sprintf "%s %s" (translate_exp e1 v_map) (translate_exp e2 v_map)

  (* 인덱싱: index(e1, e2) *)
  | IdxE (e1, e2) ->
      Printf.sprintf "index(%s, %s)" (translate_exp e1 v_map) (translate_exp e2 v_map)

  (* 슬라이스: slice(e, i, j) *)
  | SliceE (e1, e2, e3) ->
      Printf.sprintf "slice(%s, %s, %s)" (translate_exp e1 v_map) (translate_exp e2 v_map) (translate_exp e3 v_map)

  (* 상태 업데이트: e1 [. FIELD <- e2] *)
  | UpdE (e1, path, e2) ->
      Printf.sprintf "%s[%s <- %s]" (translate_exp e1 v_map) (translate_path path v_map) (translate_exp e2 v_map)

  (* 상태 확장: e1 [path =.. e2] *)
  | ExtE (e1, path, e2) ->
      Printf.sprintf "%s[%s =++ %s]" (translate_exp e1 v_map) (translate_path path v_map) (translate_exp e2 v_map)

  (* 옵셔널: Some e -> e, None -> eps *)
  | OptE (Some e1) -> translate_exp e1 v_map
  | OptE None -> "eps"

  (* 옵셔널 언래핑: e! -> e *)
  | TheE e1 -> translate_exp e1 v_map

  (* 반복(Iteration): 상위 문맥에서 처리하므로 내부 식만 번역 *)
  | IterE (e1, _) -> translate_exp e1 v_map

  (* 조건식: if c then e1 else e2 *)
  | IfE (c, e1, e2) ->
      Printf.sprintf "if %s then %s else %s fi" (translate_exp c v_map) (translate_exp e1 v_map) (translate_exp e2 v_map)

  (* 리프트(coercion strip): _? <: _* *)
  | LiftE e1 -> translate_exp e1 v_map

(* 경로(Path) 변환 함수: UpdE, ExtE에서 사용 *)
and translate_path (p : path) (v_map : (string * string) list) : string =
  match p.it with
  | RootP -> ""
  | IdxP (p1, e) ->
      let base = translate_path p1 v_map in
      let idx = translate_exp e v_map in
      if base = "" then Printf.sprintf "[%s]" idx
      else Printf.sprintf "%s[%s]" base idx
  | SliceP (p1, e1, e2) ->
      Printf.sprintf "%s[%s : %s]" (translate_path p1 v_map) (translate_exp e1 v_map) (translate_exp e2 v_map)
  | DotP (p1, atom) ->
      let qid = "'" ^ String.uppercase_ascii (sanitize (Xl.Atom.name atom)) in
      let base = translate_path p1 v_map in
      if base = "" then Printf.sprintf ".%s" qid
      else Printf.sprintf "%s.%s" base qid

and translate_arg (a : arg) (v_map : (string * string) list) : string =
  match a.it with
  | ExpA e -> translate_exp e v_map
  | TypA _ -> "TYPE_ARG"
  | DefA _ -> "DEF_ARG"
  | GramA _ -> "GRAM_ARG"

(* 전제조건(Premise) 변환 함수 (§8) *)
and translate_prem (p : prem) (v_map : (string * string) list) : string =
  match p.it with
  | IfPr e -> translate_exp e v_map
  | RulePr (id, _mixop, e) ->
      Printf.sprintf "%s(%s)" (sanitize id.it) (translate_exp e v_map)
  | LetPr (e1, e2, _) ->
      Printf.sprintf "(%s := %s)" (translate_exp e1 v_map) (translate_exp e2 v_map)
  | ElsePr -> "owise"
  | IterPr (inner_p, _) -> translate_prem inner_p v_map
  | NegPr inner_p ->
      Printf.sprintf "not(%s)" (translate_prem inner_p v_map)

and translate_typ (t : typ) (v_map : (string * string) list) : string =
  match t.it with
  | VarT (id, args) -> 
      let name = try List.assoc id.it v_map with Not_found -> sanitize id.it in
      if args = [] then name
      else 
        let arg_strs = List.map (fun a -> translate_arg a v_map) args in
        Printf.sprintf "%s(%s)" name (String.concat ", " arg_strs)
  | IterT (inner, _) -> translate_typ inner v_map
  | _ -> "WasmType"

(* ------------------- Main: 정의 번역 (translate_definition) ------------------- *)
let rec translate_definition (d : def) : string =
  match d.it with
  | RecD defs -> String.concat "\n" (List.map (fun d -> translate_definition d) defs)

  | TypD (id, params, insts) ->
      let name = sanitize id.it in
    
      (* Maude 선언부 생성 *)
      let sig_types = String.concat " " (List.map (fun _ -> "WasmTerminal") params) in
      let op_decl = Printf.sprintf "  op %s : %s -> WasmType [ctor] .\n" name sig_types in
      
      let res = List.map (fun inst ->
        match inst.it with
        | InstD (binders, args, deftyp) ->
            (* v_map 생성 : Inn -> INN *)
            let v_map = List.filter_map (fun b ->
              match b.it with 
              | ExpB (id, _) -> Some (id.it, to_var_name id.it)
              | _ -> None
            ) binders in

            (* Binder들에 대한 typecheck 조건 생성 (예 : typecheck(INN, Inn)) *)
            let binder_conds = List.filter_map (fun b ->
              let get_cond id = Some (Printf.sprintf "typecheck(%s, %s)" (to_var_name id.it) (sanitize id.it)) in
              match b.it with
              | ExpB (id, _) -> get_cond id
              | _ -> None
            ) binders in
            
            (* 왼쪽 항(LHS) 구성 (예: num-(INN)*)
            let args_str = String.concat ", " (List.map (fun a -> translate_arg a v_map) args) in
            let full_type_name = if args_str = "" then name else name ^ "(" ^ args_str ^ ")" in

            (match deftyp.it with 
             | VariantT cases -> 
                let case_res = List.map (fun (mixop_val, (_, case_typ, prems), _) ->
                  (* 1. Mixfix 이름 생성: IF%%ELSE% -> IF-ELSE- (Maude 스타일) *)
                  let raw_cons_name = 
                    match List.flatten mixop_val with
                    | a :: _ -> Xl.Atom.name a
                    | [] -> ""
                  in
                  let maude_cons_name = sanitize raw_cons_name in

                  if prems <> [] then 
                    (* 범위 제약(uN, sN) *)
                    let conditions = List.filter_map (fun p -> match p.it with IfPr e -> Some (translate_exp e v_map) | _ -> None) prems in
                    let cond_str = String.concat " /\\ " (binder_conds @ conditions) in
                    let upper_name = String.uppercase_ascii name in (* "UN", "SN" *)
                    let var_name = "N_" ^ upper_name in (* 변수명을 N_UN, N_SN 형태로 생성 *)
                    let var_decl = if params = [] then "" else Printf.sprintf "  var %s : Nat ." var_name in
                    Printf.sprintf "%s \n  ceq typecheck(i, %s) = true \n   if %s ." var_decl full_type_name cond_str

                  else
                    (* 타입별 변수명 중복 방지를 위한 딕셔너리 카운터 *)
                    let type_counters = ref [] in
                    let get_count tname =
                      let c = (try List.assoc tname !type_counters with Not_found -> 0) + 1 in
                      type_counters := (tname, c) :: (List.remove_assoc tname !type_counters);
                      c
                    in

                    (* 인자 추출 함수: 변수명 중복 방지를 위해 카운터 사용, 타입 인자 보존 *)
                    let rec collect_params current_v_map t is_list = match t.it with
                      | VarT (tid, _) -> 
                          let v_base = to_var_name tid.it in
                          let count = get_count v_base in (* 타입별로 카운팅 *)

                          let indexed_name = if is_list then v_base ^ "*" else v_base ^ string_of_int count in
                          let sort_name = translate_typ t [] in 
                          let inherent_plural = is_plural_type tid.it in
                          let maude_sort = if is_list || inherent_plural then "WasmTerminals" else "WasmTerminal" in

                          let updated_v_map = (tid.it, indexed_name) :: current_v_map in
                          ([(indexed_name, sort_name, maude_sort)], updated_v_map)

                      | IterT (inner, iter) -> 
                          let is_lst = (iter = List || iter = List1) in
                          collect_params current_v_map inner is_lst

                      | TupT fields -> 
                          List.fold_left (fun (ps_acc, vm_acc) (_, ft) ->
                            let (ps, new_vm) = collect_params vm_acc ft is_list in
                            (ps_acc @ ps, new_vm)
                          ) ([], current_v_map) fields

                      | _ -> ([], current_v_map)
                    in

                    let (params, _) = collect_params v_map case_typ false in
                    
                    (* Maude 부품 조립 *)
                    let p_vars = List.map (fun (v, _, _) -> v) params in
                    let p_sorts = String.concat " " (List.map (fun (_, _, ms) -> ms) params) in
                    
                    let v_decl = String.concat "" (List.map (fun (v, _, ms) -> 
                        Printf.sprintf "  var %s : %s .\n" v ms
                    ) params) in

                    (* 조건문: typecheck(LOCAL*, local) 등 *)
                    let p_conds = List.map (fun (v, s, _) -> Printf.sprintf "typecheck(%s, %s)" v s) params in
                    let rhs_str = String.concat " /\\ " (binder_conds @ p_conds) in
                    let final_rhs = if rhs_str = "" then "true" else rhs_str in

                    (* Mixfix 및 빈 생성자(Juxtaposition) 좌항 포맷팅 — 구조적 interleave *)
                    let sections = mixop_sections mixop_val in
                    let lhs_usage = interleave_lhs sections p_vars in
                    let op_decl_name = interleave_op sections (List.length p_vars) in
                                        
                    let main_rule = 
                      if maude_cons_name = "" then
                        (* 1. 빈 생성자(Juxtaposition): op 선언 생략 *)
                        Printf.sprintf "\n%s  eq typecheck(%s, %s) = %s ." 
                          v_decl lhs_usage full_type_name final_rhs
                      else
                        (* 2. 일반 및 Mixfix 생성자 *)
                        Printf.sprintf "  op %s : %s -> WasmTerminal [ctor] .\n%s  eq typecheck(%s, %s) = %s ." 
                          op_decl_name p_sorts v_decl lhs_usage full_type_name final_rhs
                    in

                    (* 빈 값(eps) 규칙 생성 — 다중 인자 일반화 (Rule V-E) *)
                    let empty_rule =
                      let opt_indices = find_opt_param_indices case_typ in
                      let rules = List.map (fun opt_idx ->
                        let p_vars_eps = List.mapi (fun i v -> if i = opt_idx then "eps" else v) p_vars in
                        let p_conds_filtered = List.filteri (fun i _ -> i <> opt_idx) p_conds in
                        let rhs_str = String.concat " /\\ " (binder_conds @ p_conds_filtered) in
                        let final_rhs_eps = if rhs_str = "" then "true" else rhs_str in
                        let lhs_eps = interleave_lhs sections p_vars_eps in
                        Printf.sprintf "\n  eq typecheck(%s, %s) = %s ." lhs_eps full_type_name final_rhs_eps
                      ) opt_indices in
                      String.concat "" rules
                    in

                    (* 3. 두 규칙을 합쳐서 반환 *)
                    main_rule ^ empty_rule
                ) cases in
                String.concat "\n" (List.filter (fun s -> s <> "") case_res)

             | AliasT typ ->
                (* 1. 별칭이 가리키는 실제 타입 본체 번역 *)
                let rhs_body = match typ.it with
                  | IterT (inner, _) -> translate_typ inner v_map (* instr* -> instr *)
                  | _ -> translate_typ typ v_map
                in
                
                (* 2. 검증 대상 변수 결정 — 구조적: IterT(_, List|List1)이면 TS, 아니면 T *)
                let var_name = match typ.it with
                  | IterT (_, (List | List1)) -> "TS"
                  | _ -> "T"
                in
                
                (* 3. 바인더 조건들(예: typecheck(INN, Inn))을 /\ 로 엮음 *)
                let cond_prefix = if binder_conds = [] then "" 
                                  else String.concat " /\\ " binder_conds ^ " /\\ " in

                (* 4. 최종 Maude 등식 조립 *)
                Printf.sprintf "  eq typecheck(%s, %s) = %s typecheck(%s, %s) ." 
                  var_name full_type_name cond_prefix var_name rhs_body
             | StructT fields ->
                (* StructT: 레코드 타입 → DSL-RECORD 패턴 (Rule S-OP, S-F) *)
                (* 각 필드에 대해 변수명, 타입, Sort를 생성 *)
                let field_info = List.mapi (fun i (atom, (_, ft, _), _) ->
                  let field_name = String.uppercase_ascii (sanitize (Xl.Atom.name atom)) in
                  let qid = "'" ^ field_name in
                  (* 필드 타입의 리스트 여부를 구조적으로 판별 *)
                  let is_list = match ft.it with
                    | IterT (_, (List | List1)) -> true
                    | _ -> false
                  in
                  let inner_typ = match ft.it with
                    | IterT (inner, _) -> inner
                    | _ -> ft
                  in
                  let sort_name = translate_typ inner_typ v_map in
                  let plural = is_list || is_plural_type sort_name in
                  let maude_sort = if plural then "WasmTerminals" else "WasmTerminal" in
                  let var_name = Printf.sprintf "F_%s_%d" field_name i in
                  (qid, var_name, sort_name, maude_sort)
                ) fields in

                (* 변수 선언 *)
                let var_decls = String.concat "" (List.map (fun (_, vn, _, ms) ->
                  Printf.sprintf "  var %s : %s .\n" vn ms
                ) field_info) in

                (* LHS: {item('TYPES, F_TYPES_0) ; item('FUNCS, F_FUNCS_1) ; ...} *)
                let items = List.map (fun (qid, vn, _, _) ->
                  Printf.sprintf "item(%s, %s)" qid vn
                ) field_info in
                let lhs = "{" ^ String.concat " ; " items ^ "}" in

                (* RHS: typecheck(F_TYPES_0, deftype) /\ typecheck(F_FUNCS_1, deftype) /\ ... *)
                let conds = List.map (fun (_, vn, sn, _) ->
                  Printf.sprintf "typecheck(%s, %s)" vn sn
                ) field_info in
                let rhs_str = String.concat " /\\ " (binder_conds @ conds) in
                let final_rhs = if rhs_str = "" then "true" else rhs_str in

                Printf.sprintf "%s  eq typecheck(%s, %s) = %s ."
                  var_decls lhs full_type_name final_rhs)
      ) insts in
      op_decl ^ String.concat "\n" res
  
| DecD (id, params, result_typ, insts) ->
      let raw_func_name = id.it in
      let func_name = sanitize raw_func_name in
      let maude_func_name = if String.length func_name > 0 && func_name.[0] = '$' then func_name else "$" ^ func_name in
      
      let prefix_raw = match String.split_on_char '-' (String.uppercase_ascii func_name) with h::_ -> h | [] -> "FUNC" in
      let prefix = if String.length prefix_raw > 0 && prefix_raw.[0] = '$' then String.sub prefix_raw 1 (String.length prefix_raw - 1) else prefix_raw in

      let arg_sorts = String.concat " " (List.map (fun p -> 
          match p.it with 
          | ExpP (v_id, t) -> 
              let t_str = translate_typ t [] in
              if t_str = "bool" || t_str = "Bool" || v_id.it = "bool" then "Bool" 
              else "WasmTerminal"
          | _ -> "WasmTerminal"
      ) params) in

      let ret_sort = match result_typ.it with
          | IterT _ -> "WasmTerminals"
          | _ -> "WasmTerminal"
      in
      
      let op_decl = Printf.sprintf "  op %s : %s -> %s .\n" maude_func_name arg_sorts ret_sort in

      let eq_lines = List.map (fun inst ->
        match inst.it with
        | DefD (binders, lhs_args, rhs_exp, prem_list) ->
            let v_map = ref [] in
            let binder_conds = ref [] in
            let var_decls = ref [] in
            
            List.iter (fun b ->
                match b.it with
                | ExpB (v_id, t) ->
                    let raw_v = v_id.it in
                    let t_str = translate_typ t [] in
                    
                    if t_str = "bool" || t_str = "Bool" || raw_v = "bool" then ()
                    else begin
                        let upper_v = String.uppercase_ascii (sanitize raw_v) in
                        let upper_v = String.concat "" (String.split_on_char '-' upper_v) in
                        let maude_var = prefix ^ "_" ^ upper_v in
                        
                        v_map := (raw_v, maude_var) :: !v_map;
                        var_decls := maude_var :: !var_decls;
                        
                        let is_cap = (raw_v.[0] >= 'A' && raw_v.[0] <= 'Z') in
                        if is_cap then
                          binder_conds := Printf.sprintf "typecheck(%s, %s)" maude_var (sanitize raw_v) :: !binder_conds
                        else begin
                            let is_in = String.length t_str >= 2 && String.sub t_str 0 2 = "iN" in
                            if not is_in && t_str <> "WasmType" && t_str <> "WasmTerminal" && t_str <> "Bool" then begin
                                (* [추가됨] 여기서 t를 번역할 때 !v_map을 넘겨주면, 내부의 Inn이 BINOP_INN으로 치환됩니다! *)
                                let t_str_mapped = translate_typ t !v_map in
                                binder_conds := Printf.sprintf "typecheck(%s, %s)" maude_var t_str_mapped :: !binder_conds
                            end
                        end
                    end
                | _ -> ()
            ) binders;

            let body = translate_exp rhs_exp !v_map in
            
            let rec process_args args typs =
                match args, typs with
                | arg :: rest_args, param :: rest_typs ->
                    let is_bool = 
                        match param.it with 
                        | ExpP (v_id, t) -> 
                            let t_str = translate_typ t [] in
                            (t_str = "bool" || t_str = "Bool" || v_id.it = "bool")
                        | _ -> false 
                    in
                    let a_str = match arg.it with ExpA e -> translate_exp e !v_map | _ -> "UNKNOWN" in
                    let final_a = 
                        if is_bool then
                            if body = "0" then "false" else if body = "1" then "true" else a_str
                        else a_str
                    in
                    final_a :: process_args rest_args rest_typs
                | [], _ -> []
                | _, [] -> []
            in
            
            let arg_strs = process_args lhs_args params in
            let arg_str = String.concat ", " arg_strs in
            
            let unique_vars = List.rev !var_decls in
            let is_n_var v = let len = String.length v in (len >= 2 && String.sub v (len-2) 2 = "_N") || (len >= 4 && String.sub v (len-4) 4 = "_INN") in
            let vars_n = List.filter is_n_var unique_vars in
            let vars_i = List.filter (fun v -> not (is_n_var v)) unique_vars in
            
            let decl_str = 
              (if vars_n = [] then "" else if List.length vars_n = 1 then Printf.sprintf "  var %s : WasmTerminal .\n" (List.hd vars_n) else Printf.sprintf "  vars %s : WasmTerminal .\n" (String.concat " " vars_n)) ^
              (if vars_i = [] then "" else if List.length vars_i = 1 then Printf.sprintf "  var %s : WasmTerminal .\n" (List.hd vars_i) else Printf.sprintf "  vars %s : WasmTerminal .\n" (String.concat " " vars_i))
            in

            (* 전제조건(Premises)을 변환하여 binder 조건과 합침 *)
            let prem_conds = List.filter_map (fun p ->
              let s = translate_prem p !v_map in
              if s = "" || s = "owise" then None else Some s
            ) prem_list in
            let has_owise = List.exists (fun p -> match p.it with ElsePr -> true | _ -> false) prem_list in
            let all_conds = List.rev !binder_conds @ prem_conds in
            let owise_attr = if has_owise then " [owise]" else "" in
            let cond_str = if all_conds = [] then "" else " \n      if " ^ String.concat " /\\ " all_conds in
            let eq_word = if all_conds = [] && not has_owise then "eq" else "ceq" in
            let line_sep = if decl_str = "" then "" else "\n" in
            
            if arg_strs = [] then 
                Printf.sprintf "%s%s  %s %s = %s%s .%s" line_sep decl_str eq_word maude_func_name body cond_str owise_attr
            else 
                Printf.sprintf "%s%s  %s %s(%s) = %s%s .%s" line_sep decl_str eq_word maude_func_name arg_str body cond_str owise_attr
      ) insts in
      "\n" ^ op_decl ^ String.concat "\n" eq_lines ^ "\n"

  | RelD (id, _mixop, _typ, rules) ->
      (* RelD: 추론 규칙 관계 → `op rel : ... -> Bool .` + `eq/ceq rel(...) = true` *)
      let rel_name = sanitize id.it in

      (* 관계의 인자 arity를 첫 번째 rule의 binder 수에서 추론 *)
      let arity = match rules with
        | r :: _ -> (match r.it with RuleD (_, binders, _, _, _) -> List.length binders)
        | [] -> 0
      in
      let arg_sorts = String.concat " " (List.init arity (fun _ -> "WasmTerminal")) in
      let op_decl = Printf.sprintf "\n  op %s : %s -> Bool .\n" rel_name arg_sorts in

      let rule_lines = List.map (fun r ->
        match r.it with
        | RuleD (case_id, binders, _rule_mixop, conclusion, prem_list) ->
            let v_map = ref [] in
            let var_decls = ref [] in
            let binder_conds = ref [] in

            (* 바인더에서 변수 매핑 및 타입 조건 생성 *)
            let rule_prefix = String.uppercase_ascii (sanitize case_id.it) in
            List.iter (fun b ->
              match b.it with
              | ExpB (v_id, t) ->
                  let raw_v = v_id.it in
                  let t_str = translate_typ t [] in
                  if t_str = "bool" || t_str = "Bool" || raw_v = "bool" then ()
                  else begin
                    let upper_v = String.uppercase_ascii (sanitize raw_v) in
                    let upper_v = String.concat "" (String.split_on_char '-' upper_v) in
                    let maude_var = rule_prefix ^ "_" ^ upper_v in
                    v_map := (raw_v, maude_var) :: !v_map;
                    var_decls := maude_var :: !var_decls;

                    let is_cap = (raw_v.[0] >= 'A' && raw_v.[0] <= 'Z') in
                    if is_cap then
                      binder_conds := Printf.sprintf "typecheck(%s, %s)" maude_var (sanitize raw_v) :: !binder_conds
                    else begin
                      let is_in = String.length t_str >= 2 && String.sub t_str 0 2 = "iN" in
                      if not is_in && t_str <> "WasmType" && t_str <> "WasmTerminal" && t_str <> "Bool" then
                        let t_str_mapped = translate_typ t !v_map in
                        binder_conds := Printf.sprintf "typecheck(%s, %s)" maude_var t_str_mapped :: !binder_conds
                    end
                  end
              | _ -> ()
            ) binders;

            (* 결론(Conclusion) 번역 → LHS *)
            let lhs = translate_exp conclusion !v_map in

            (* 전제조건(Premises) 번역 *)
            let prem_conds = List.filter_map (fun p ->
              let s = translate_prem p !v_map in
              if s = "" || s = "owise" then None else Some s
            ) prem_list in
            let all_conds = List.rev !binder_conds @ prem_conds in

            (* 변수 선언 *)
            let unique_vars = List.rev !var_decls in
            let decl_str =
              if unique_vars = [] then ""
              else if List.length unique_vars = 1 then
                Printf.sprintf "  var %s : WasmTerminal .\n" (List.hd unique_vars)
              else
                Printf.sprintf "  vars %s : WasmTerminal .\n" (String.concat " " unique_vars)
            in

            (* eq/ceq 생성 *)
            let cond_str = if all_conds = [] then "" else " \n      if " ^ String.concat " /\\ " all_conds in
            let eq_word = if all_conds = [] then "eq" else "ceq" in
            let line_sep = if decl_str = "" then "" else "\n" in
            Printf.sprintf "%s%s  %s %s(%s) = true%s ."
              line_sep decl_str eq_word rel_name lhs cond_str
      ) rules in
      op_decl ^ String.concat "\n" rule_lines ^ "\n"

  (* GramD: binary/text 문법 — 변환 범위 밖 *)
  | GramD _ -> ""
  (* HintD: 비출력 메타데이터 *)
  | HintD _ -> ""