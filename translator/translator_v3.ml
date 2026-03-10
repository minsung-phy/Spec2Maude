(* version3-1 for 3-1.spectec -> 3-1.maude *)

open Util.Source
open Il.Ast

let header =
  "load 2 \n\n" ^
  "mod 3_1_NUMERICS_SCALAR is\n" ^
  "  inc DSL-TERM .\n" ^
  "  inc DSL-PRETYPE .\n" ^
  "  inc DSL-EXEC .\n\n" ^
  "  inc 2_0_VALIDATION .\n\n" ^
  "  subsort Int < WasmTerminal .\n" ^
  "  subsort Nat < WasmTerminal .\n\n" ^
  "  op nat : -> WasmType [ctor] . \n" ^
  "  var I : Int .\n" ^
  "  var T : WasmTerminal .\n"

let footer = "\nendm"

(* ------------------- Helper ------------------- *)

(* 이름에서 _를 -로 바꾸고 끝에 %를 제거하는 함수 *)
let sanitize name =
  let s = String.map (fun c -> if c = '_' then '-' else c) name in
  if String.length s > 0 && s.[String.length s - 1] = '%' then
    String.sub s 0 (String.length s - 1)
  else s

(* 변수명을 대문자로 변환 (Inn -> INN) *)
let to_var_name name = String.uppercase_ascii (sanitize name)

(* Type Environment Registry : *)
(* 겉보기엔 단수형(VarT)이지만, 의미론적으로 반드시 리스트(WasmTerminals)로 취급해야 하는 예외 타입들의 집합 *)
let is_plural_type (type_name : string) : bool =
  match String.lowercase_ascii type_name with
  | "expr" | "resulttype" -> true    (* Wasm Core Spec 기준: expr ::= instr* / 공식문서 structure/instructions 마지막 *)
  (* 나중에 Wasm 명세에 resulttype (valtype* 의미) 같은 게 나오면 여기에 추가 *)
  | _ -> false


(* 수식(Expression) 변환 함수: 연산자 이름을 그대로 사용함 *)
let rec translate_exp (e : exp) (v_map : (string * string) list) : string =
  match e.it with
  | VarE id -> 
      (try List.assoc id.it v_map 
       with Not_found -> 
         (* 상수(ADD, SUB, EQ, false, true 등)는 변환하지 않고 그대로 출력 *)
         if id.it = "ADD" || id.it = "SUB" || id.it = "EQ" || id.it = "false" || id.it = "true" then id.it 
         else String.uppercase_ascii id.it)
  
  | CaseE (mixop, inner_exp) ->
      let op_name = 
        try List.flatten mixop |> List.map Xl.Atom.name |> String.concat "" 
        with _ -> "UNKNOWN_CASE"
      in
      (* $ 기호 또는 % 포맷팅 기호는 껍데기를 벗기고 내부 수식을 평가! *)
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
      
  | _ -> "UNKNOWN_EXP"

and translate_arg (a : arg) (v_map : (string * string) list) : string =
  match a.it with
  | ExpA e -> translate_exp e v_map
  | TypA t -> translate_typ t v_map
  | _ -> "0"

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
  | RecD defs -> String.concat "\n" (List.map translate_definition defs)

  | TypD (id, params, insts) ->
      let name = sanitize id.it in
    
      (* Maude 선언부 생성 *)
      let sig_types = if params = [] then "" else "WasmTerminal" in
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
                    let p_phs = String.concat "" (List.map (fun _ -> " _") params) in
                    let p_sorts = String.concat " " (List.map (fun (_, _, ms) -> ms) params) in
                    
                    let v_decl = String.concat "" (List.map (fun (v, _, ms) -> 
                        Printf.sprintf "  var %s : %s .\n" v ms
                    ) params) in

                    (* 조건문: typecheck(LOCAL*, local) 등 *)
                    let p_conds = List.map (fun (v, s, _) -> Printf.sprintf "typecheck(%s, %s)" v s) params in
                    let rhs_str = String.concat " /\\ " (binder_conds @ p_conds) in
                    let final_rhs = if rhs_str = "" then "true" else rhs_str in

                    (* Mixfix 및 빈 생성자(Juxtaposition) 좌항 포맷팅 *)
                    let lhs_usage = 
                      if maude_cons_name = "->-" && List.length p_vars = 3 then
                        Printf.sprintf "%s ->- %s %s" (List.nth p_vars 0) (List.nth p_vars 1) (List.nth p_vars 2)
                      else if maude_cons_name = "" then
                        String.concat " " p_vars
                      else if p_vars = [] then
                        maude_cons_name
                      else
                        maude_cons_name ^ " " ^ String.concat " " p_vars
                    in

                    let op_decl_name = 
                      if maude_cons_name = "->-" && List.length p_vars = 3 then
                        "_ ->- _ _"
                      else
                        maude_cons_name ^ p_phs
                    in
                                        
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

                    (* 빈 값(eps) 규칙 생성 *)
                    let empty_rule = 
                      (* 내부 구조에서 Opt(Optional) 타입을 찾아 eps를 반환하는 재귀 함수 *)
                      let rec find_iter t = match t.it with
                        | IterT (_, iter) -> 
                            if iter = Opt then Some "eps" else None
                        | TupT fields -> 
                            (* 튜플 안의 필드들을 하나씩 뒤져서 IterT가 있는지 확인 *)
                            List.find_map (fun (_, f) -> find_iter f) fields
                        | _ -> None
                      in
                      
                      (* 인자가 1개일 때, 내부 구조가 Optional인 경우에만 eps 규칙 생성 *)
                      if List.length params = 1 then
                        match find_iter case_typ with
                        | Some sym -> 
                            let rhs_empty = if binder_conds = [] then "true" else String.concat " /\\ " binder_conds in
                            Printf.sprintf "\n  eq typecheck(%s %s, %s) = %s ." maude_cons_name sym full_type_name rhs_empty
                        | None -> ""
                      else "" 
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
                
                (* 2. 검증 대상 변수 결정 (expr은 리스트이므로 INSTRS, 나머지는 T) *)
                let var_name = if name = "expr" then "INSTRS" else "T" in
                
                (* 3. 바인더 조건들(예: typecheck(INN, Inn))을 /\ 로 엮음 *)
                let cond_prefix = if binder_conds = [] then "" 
                                  else String.concat " /\\ " binder_conds ^ " /\\ " in

                (* 4. 최종 Maude 등식 조립 *)
                Printf.sprintf "  eq typecheck(%s, %s) = %s typecheck(%s, %s) ." 
                  var_name full_type_name cond_prefix var_name rhs_body
             | _ -> "")
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
        | DefD (binders, lhs_args, rhs_exp, _) ->
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

            let cond_str = if !binder_conds = [] then "" else " \n      if " ^ String.concat " /\\ " (List.rev !binder_conds) in
            let eq_word = if !binder_conds = [] then "eq" else "ceq" in
            let line_sep = if decl_str = "" then "" else "\n" in
            
            if arg_strs = [] then 
                Printf.sprintf "%s%s  %s %s = %s%s ." line_sep decl_str eq_word maude_func_name body cond_str
            else 
                Printf.sprintf "%s%s  %s %s(%s) = %s%s ." line_sep decl_str eq_word maude_func_name arg_str body cond_str
      ) insts in
      "\n" ^ op_decl ^ String.concat "\n" eq_lines ^ "\n"

  | _ -> ""