(* version1-3 for 1-3.spectec -> 1-3.maude *)

open Util.Source
open Il.Ast

let header =
  "load dsl/pretype \n\n" ^
  "load 1-1 \n\n" ^
  "load 1-2 \n\n" ^
  "mod 1_3_SYNTAX_INSTRUCTIONS is\n" ^
  "  inc DSL-TERM .\n" ^
  "  inc DSL-PRETYPE .\n" ^
  "  inc DSL-EXEC .\n\n" ^
  "  inc 1_1_SYNTAX_VALUES .\n\n" ^
  "  inc 1_2_SYNTAX_TYPES .\n\n" ^
  "  subsort Int < WasmTerminal .\n" ^
  "  subsort Nat < WasmTerminal .\n\n" ^
  "  op nat : -> WasmType . \n" ^
  "  var i : Int .\n" ^
  "  var T : WasmTerminal .\n"

let footer = "\nendm"

(* 이름에서 _를 -로 바꾸고 끝에 %를 제거하는 함수 *)
let sanitize name =
  let s = String.map (fun c -> if c = '_' then '-' else c) name in
  if String.length s > 0 && s.[String.length s - 1] = '%' then
    String.sub s 0 (String.length s - 1)
  else s

(* 변수명을 대문자로 변환 (Inn -> INN) *)
let to_var_name name = String.uppercase_ascii (sanitize name)

(* ------------------- Helper: 수식 번역 ------------------- *)
(* 수식(Expression) 변환 함수: 연산자 이름을 그대로 사용함 *)
let rec translate_exp (e : exp) (v_map : (string * string) list) : string =
  match e.it with
  | VarE id -> 
      (* v_map(nt -> NT)에 있으면 바꾸고, 없으면 대문자로 바꿔서 리턴 *)
      (try List.assoc id.it v_map 
        with Not_found -> String.uppercase_ascii id.it) (* v_map에 안잡히는게 많아서 이렇게 진행 *)
  
  | CaseE (mixop, _) ->
      (* I32, I64, NULL 같은 생성자들이 여기에 있음 *)
      (match mixop with
       | (a :: _) :: _ -> Xl.Atom.name a  (* Atom 이름을 그대로 가져옴 *)
       | _ -> "UNKNOWN_CASE")

  | NumE n -> 
      (match n with 
       | `Nat z | `Int z -> Z.to_string z 
       | `Rat q -> Z.to_string (Q.num q) ^ "/" ^ Z.to_string (Q.den q)
       | `Real r -> Printf.sprintf "%.17g" r)
       
  | CvtE (e1, _, _) -> translate_exp e1 v_map
  | SubE (e1, _, _) -> translate_exp e1 v_map
  
  | UnE (op, _, e1) -> 
      let op_str = (match (op : unop) with 
        | `MinusOp -> "-" 
        | `PlusOp -> "+" 
        | `NotOp -> "not "
      ) in
      Printf.sprintf "%s(%s)" op_str (translate_exp e1 v_map)
      
  | BinE (op, _, e1, e2) -> 
      let op_str = (match (op : binop) with 
        | `AddOp -> "+" 
        | `SubOp -> "-" 
        | `MulOp -> "*" 
        | `DivOp -> "/" 
        | `ModOp -> "%" 
        | `PowOp -> "^"
        | `AndOp -> "/\\" 
        | `OrOp -> "\\/" (* Maude 표준 논리합은 \/ *)
        | `ImplOp -> "implies" 
        | `EquivOp -> "==" 
      ) in
      Printf.sprintf "(%s %s %s)" (translate_exp e1 v_map) op_str (translate_exp e2 v_map)
  
  | CmpE (op, _, e1, e2) ->
      let op_str = (match (op : cmpop) with
        | `LtOp -> "<" 
        | `GtOp -> ">" 
        | `LeOp -> "<=" 
        | `GeOp -> ">=" 
        | `EqOp -> "==" 
        | `NeOp -> "=/="
      ) in
      Printf.sprintf "(%s %s %s)" (translate_exp e1 v_map) op_str (translate_exp e2 v_map)

  | CallE (id, args) -> 
      let arg_strs = List.map (fun a -> translate_arg a v_map) args in
      (* 이름은 sanitize 하고 *)
      let fname = sanitize id.it in
      (* 2. 만약 이름이 $로 시작하지 않는다면 $를 강제로 붙임 *)
      let final_name = if String.length fname > 0 && fname.[0] = '$' then 
                         fname 
                       else 
                         "$" ^ fname 
      in
      Printf.sprintf "%s(%s)" final_name (String.concat ", " arg_strs)
      
  | _ -> "0"

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
  | _ -> "WasmType"

(* ------------------- Main: 정의 번역 (translate_definition) ------------------- *)
let rec translate_definition (d : def) : string =
  match d.it with
  | RecD defs -> String.concat "\n" (List.map translate_definition defs)

  | TypD (id, params, insts) ->
      let name = sanitize id.it in
    
      (* Maude 선언부 생성 *)
      let sig_types = if params = [] then "" else "WasmTerminal" in
      let op_decl = Printf.sprintf "  op %s : %s -> WasmType .\n" name sig_types in
      
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
                  let raw_cons_name = match mixop_val with (a :: _) :: _ -> Xl.Atom.name a | _ -> "UNKNOWN" in
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
                    (* 인자 추출 함수: 변수명 중복 방지를 위해 카운터 사용, 타입 인자 보존 *)
                    let rec collect_params counter current_v_map t = match t.it with
                      | VarT (tid, _) -> 
                          let v_base = to_var_name tid.it in
                          let count = !counter in
                          incr counter;
                          let indexed_name = v_base ^ string_of_int count in
                          
                          let sort_name = translate_typ t current_v_map in 
                          
                          let updated_v_map = (tid.it, indexed_name) :: current_v_map in
                          ([(indexed_name, sort_name)], updated_v_map)
                      | IterT (inner, _) -> collect_params counter current_v_map inner
                      | TupT fields -> 
                          List.fold_left (fun (ps_acc, vm_acc) (_, ft) ->
                            let (ps, new_vm) = collect_params counter vm_acc ft in
                            (ps_acc @ ps, new_vm)
                          ) ([], current_v_map) fields
                      | _ -> ([], current_v_map)
                    in
                    let param_counter = ref 1 in
                    let (params, _) = collect_params param_counter v_map case_typ in
                    
                    (* Maude 부품 조립 *)
                    let p_vars = List.map fst params in
                    let p_phs = String.concat "" (List.map (fun _ -> " _") params) in
                    let p_sorts = String.concat " " (List.map (fun _ -> "WasmTerminal") params) in
                    
                    let v_decl = if p_vars = [] then "" 
                                 else Printf.sprintf "  vars %s : WasmTerminal .\n" (String.concat " " p_vars) in

                    (* 조건문: typecheck(NUMTYPE1, numtype) /\ typecheck(NUM2, num-(NUMTYPE1)) *)
                    let p_conds = List.map (fun (v, s) -> Printf.sprintf "typecheck(%s, %s)" v s) params in
                    let rhs_str = String.concat " /\\ " (binder_conds @ p_conds) in
                    
                    let main_rule = 
                      if p_vars = [] then
                        Printf.sprintf "  op %s : -> WasmTerminal .\n  eq typecheck(%s, %s) = %s ." 
                          maude_cons_name maude_cons_name full_type_name (if rhs_str = "" then "true" else rhs_str)
                      else
                        Printf.sprintf "  op %s%s : %s -> WasmTerminal .\n%s  eq typecheck(%s %s, %s) = %s ." 
                          maude_cons_name p_phs p_sorts v_decl maude_cons_name (String.concat " " p_vars) full_type_name rhs_str
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
  
  | DecD (id, params, _, insts) ->
    let func_name = id.it in
    
    (* 1. op 선언 *)
    let arg_sorts = String.concat " " (List.map (fun _ -> "WasmTerminal") params) in
    
    let op_decl = Printf.sprintf "  op $%s : %s -> WasmTerminal .\n" func_name arg_sorts in

    (* 2. params에서 변수명 추출 및 대문자 변환 (NT, VARNUMTYPE 등) *)
    (* v_map을 만들어서 eq 문장 번역할 때 nt -> NT로 바뀌게 함 *)
    let local_v_map = List.filter_map (fun p ->
      match p.it with
      | ExpP (v_id, _) ->
          let upper_v = String.uppercase_ascii v_id.it in
          Some (v_id.it, upper_v)
      | _ -> None
    ) params in
    
    (* 3. var 선언 (위에서 만든 mapping을 그대로 사용!) *)
    let var_decls = List.map (fun p ->
        match p.it with
        | ExpP (v_id, _) -> 
            Printf.sprintf "  var %s : WasmTerminal .\n" (String.uppercase_ascii v_id.it)
        | _ -> ""
      ) params |> String.concat "" in

    (* 4. eq 문장 생성 (v_map을 적용해서 소문자 인자를 대문자 변수로 치환) *)
    let eq_lines = List.map (fun inst ->
      match inst.it with
      | DefD (_, lhs_args, rhs_exp, _) ->
          let body = translate_exp rhs_exp local_v_map in
          
          match lhs_args with
          | arg :: _ -> (
              match arg.it with
                | ExpA e -> (
                    match e.it with
                      | VarE _ ->
                          let arg_str = translate_exp e local_v_map in
                          Printf.sprintf "  var %s : WasmTerminal .\n  eq $%s(%s) = %s ." arg_str func_name arg_str body
                      | _ -> (* CaseE 포함 *)
                          let arg_str = translate_exp e local_v_map in
                          Printf.sprintf "  eq %s(%s) = %s ." func_name arg_str body
                )
                | _ -> Printf.sprintf "  eq %s(UNKNOWN) = %s ." func_name body
            )
          | [] -> (* 인자가 아예 없을 때 *)
              Printf.sprintf "  eq %s = %s ." func_name body
    ) insts in
    "\n" ^ op_decl ^ var_decls ^ (String.concat "\n" eq_lines) ^ "\n"

  | _ -> ""