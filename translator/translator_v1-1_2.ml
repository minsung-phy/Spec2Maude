(* version1-1(2) for 1-1.spectec -> 1-1.maude *)

open Util.Source
open Il.Ast

let header =
  "load dsl/pretype \n\n" ^
  "mod 1_1_SYNTAX_VALUES is\n" ^
  "  inc DSL-TERM .\n" ^
  "  inc DSL-PRETYPE .\n" ^
  "  inc DSL-EXEC .\n\n" ^
  "  subsort Int < WasmTerminal .\n" ^
  "  subsort Nat < WasmTerminal .\n\n" ^
  "  op nat : -> WasmType . \n" ^
  "  var i : Int .\n" ^
  "  var T : WasmTerminal .\n"

let footer = "\nendm"

(* ------------------- Helper: 수식 번역 (translate_exp) ------------------- *)
(* --- 수식(Expression) 변환 함수: 네 연산자 이름을 그대로 사용함 --- *)
let rec translate_exp (e : exp) (v_map : (string * string) list) : string =
  match e.it with
  | VarE id -> 
      (* 1. v_map에서 치환할 변수(N -> N_UN 등)가 있는지 먼저 확인 *)
      (try List.assoc id.it v_map with Not_found -> 
         (* 2. 없으면 기존처럼 i, n 등을 처리 *)
         if id.it = "i" || id.it = "n" then "i" 
         else id.it)
      
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
        | `OrOp -> "\\/" (* Maude 표준 논리합은 \/ 야 *)
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

(* 상호 참조를 위해 translate_arg와 translate_typ도 v_map을 받도록 수정 *)
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
                let case_res = List.map (fun (_, (_, _, prems), _) ->
                   let conditions = List.filter_map (fun p ->
                     match p.it with
                     | IfPr e -> Some (translate_exp e v_map)
                     | _ -> None
                   ) prems in
                   let cond_str = String.concat " /\\ " conditions in
                   if cond_str = "" then "" 
                   else Printf.sprintf "  ceq typecheck(i, %s(%s)) = true \n   if typecheck(%s, N) /\\ %s ." 
                          name var_name var_name cond_str
                 ) cases in
                 String.concat "\n" case_res
             | _ -> "")
      ) insts in
      op_decl ^ var_decl ^ String.concat "\n" res
  
  | _ -> ""