(* version1-2 for 1-2.spectec -> 1-2.maude *)
(* 문제점 : syntax typeuse/sem = | ... | deftype 와 syntax valtype/syn = | numtype | ... 이 변환이 안됌
           -> 나중에 수정하자 ...
*)

open Util.Source
open Il.Ast

let header =
  "load dsl/pretype \n\n" ^
  "load 1-1 \n\n" ^
  "mod 1_2_SYNTAX_TYPES is\n" ^
  "  inc DSL-TERM .\n" ^
  "  inc DSL-PRETYPE .\n" ^
  "  inc DSL-EXEC .\n\n" ^
  "  inc 1_1_SYNTAX_VALUES .\n\n" ^
  "  subsort Int < WasmTerminal .\n" ^
  "  subsort Nat < WasmTerminal .\n\n" ^
  "  op nat : -> WasmType . \n" ^
  "  var i : Int .\n" ^
  "  var T : WasmTerminal .\n"

let footer = "\nendm"

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
      Printf.sprintf "%s(%s)" id.it (String.concat ", " arg_strs)
      
  | _ -> "0"

and translate_arg (a : arg) (v_map : (string * string) list) : string =
  match a.it with
  | ExpA e -> translate_exp e v_map
  | TypA t -> translate_typ t v_map
  | _ -> "0"

and translate_typ (t : typ) (v_map : (string * string) list) : string =
  match t.it with
  | VarT (id, args) -> 
      if args = [] then id.it 
      else 
        let arg_strs = List.map (fun a -> translate_arg a v_map) args in
        Printf.sprintf "%s(%s)" id.it (String.concat ", " arg_strs)
  | _ -> "WasmType"

(* ------------------- Main: 정의 번역 (translate_definition) ------------------- *)
let rec translate_definition (d : def) : string =
  match d.it with
  | RecD defs -> String.concat "\n" (List.map translate_definition defs)

  | TypD (id, params, insts) ->
      let name = id.it in
      let upper_name = String.uppercase_ascii name in (* "UN", "SN" *)
      let var_name = "N_" ^ upper_name in (* 변수명을 N_UN, N_SN 형태로 생성 *)

      (* Maude 선언부 생성 *)
      let v_map = [("N", var_name); ("i", "i")] in
      
      let sig_types = if params = [] then "" else "WasmTerminal" in
      let op_decl = Printf.sprintf "  op %s : %s -> WasmType .\n" name sig_types in
      let var_decl = if params = [] then "" else Printf.sprintf "  var %s : Nat .\n" var_name in

      let full_name = if params = [] then name 
                      else Printf.sprintf "%s(%s)" name var_name in

      let res = List.map (fun inst ->
        match inst.it with
        | InstD (_, _, deftyp) ->
            (match deftyp.it with 
             | AliasT typ -> (* for u8, idx 같은 단순 별칭 *)
                 Printf.sprintf "  eq typecheck(T, %s) = typecheck(T, %s) ." 
                   full_name (translate_typ typ v_map)
             | VariantT cases -> (* for uN, sN 같은 범위 조건형 *)
                let case_res = List.map (fun (mixop_val, (binders, _, prems), _) ->
                  (* 생성자 이름 가져오기 (I32, I64, F32, F64, NULL 등) *)
                  let cons_name = 
                    match mixop_val with
                    | (a :: _) :: _ -> Xl.Atom.name a
                    | _ -> "UNKNOWN"
                  in
                  
                  if prems <> [] then (* prems != [] *)
                     (* [1-1 로직] uN, sN 같은 범위 조건형 처리 *)
                     let conditions = List.filter_map (fun p ->
                       match p.it with
                       | IfPr e -> Some (translate_exp e v_map)
                       | _ -> None
                     ) prems in
                     let cond_str = String.concat " /\\ " conditions in
                        if cond_str = "" then "" 
                        else Printf.sprintf "  ceq typecheck(i, %s(%s)) = true \n   if typecheck(%s, N) /\\ %s ."  
                          name var_name var_name cond_str

                   else if binders = [] then
                     (* [1-2 추가] null, addrtype 같은 단순 생성자 처리 *)
                     (* 결과: op NULL : -> WasmTerminal . eq typecheck(NULL, null) = true . *)
                     (* 기준을 binders로 한 이유 : 인자가 있는 _DEF, _IDX랑 구분하기 위해 *)
                     Printf.sprintf "  op %s : -> WasmTerminal .\n  eq typecheck(%s, %s) = true ." 
                      cons_name cons_name name
                   
                   else
                     (* 1. Maude 안전 이름 생성: _IDX -> -IDX *)
                     let maude_cons_name = 
                       if String.length cons_name > 0 && cons_name.[0] = '_' then 
                        "-" ^ String.sub cons_name 1 (String.length cons_name - 1)
                       else cons_name
                     in

                     (* 2. Mixfix 자리 표시자 (_) 생성 (인자 개수만큼) *)
                     let placeholders = String.concat " " (List.map (fun _ -> "_") binders) in
                     
                     (* 3. 인자 타입 나열 (WasmTerminal ...) *)
                     let sorts = String.concat " " (List.map (fun _ -> "WasmTerminal") binders) in
                     
                     (* 4. 규칙용 변수 생성 (괄호 없이 공백 구분) *)
                     let vars_list = List.mapi (fun i _ -> Printf.sprintf "X%d" i) binders in
                     let vars_str = String.concat " " vars_list in
                     let var_decl = Printf.sprintf "  vars %s : WasmTerminal .\n" vars_str in

                     (* 5. 최종 Maude 문장 조립 (정답지와 99% 일치) *)
                     Printf.sprintf "  op %s %s : %s -> WasmTerminal .\n%s  eq typecheck(%s %s, %s) = true ." 
                      maude_cons_name placeholders sorts var_decl maude_cons_name vars_str name
                 ) cases in
                 String.concat "\n" (List.filter (fun s -> s <> "") case_res)
             | _ -> "")
      ) insts in
      op_decl ^ var_decl ^ String.concat "\n" res
  
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