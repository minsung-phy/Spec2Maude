(* version1-1(1) for 1-1.spectec -> 1-1.maude *)

open Util.Source
open Il.Ast

(* Maude 시스템 헤더: 선배님의 DSL 구조 반영 *)
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
  "  var N1 N2 N3 N4 N5 N6 : Nat .\n" ^
  "  var T : WasmTerminal .\n"

let footer = "\nendm"

(* --- 상호 재귀 변환 함수 --- *)

let rec translate_exp (e : exp) : string =
  match e.it with
  | VarE id -> 
      if id.it = "N" then "N1" 
      else if id.it = "i" || id.it = "n" then "i" 
      else id.it
      
  | NumE n -> 
      (match n with 
       | `Nat z | `Int z -> Z.to_string z 
       | `Rat q -> Z.to_string (Q.num q) ^ "/" ^ Z.to_string (Q.den q)
       | `Real r -> Printf.sprintf "%.17g" r)
       
  (* 핵심 추가 : 변환 노드들은 알맹이만 쏙 빼서 다시 번역*)
  | CvtE (e1, _, _) -> translate_exp e1
  | SubE (e1, _, _) -> translate_exp e1
  
  | UnE (op, _, e1) -> 
      let op_str = (match (op : unop) with `MinusOp -> "-" | `PlusOp -> "+" | `NotOp -> "not ") in
      Printf.sprintf "%s(%s)" op_str (translate_exp e1)
      
  | BinE (op, _, e1, e2) -> 
      let op_str = (match (op : binop) with 
        | `AddOp -> "+" | `SubOp -> "-" | `MulOp -> "*" 
        | `DivOp -> "/" | `ModOp -> "%" | `PowOp -> "^"
        | `AndOp -> "/\\" | `OrOp -> "or" 
        | `ImplOp -> "implies" | `EquivOp -> "==" ) in
      Printf.sprintf "(%s %s %s)" (translate_exp e1) op_str (translate_exp e2)
  
  | CmpE (op, _, e1, e2) ->
      let op_str = (match (op : cmpop) with
        | `LtOp -> "<" | `GtOp -> ">" | `LeOp -> "<=" | `GeOp -> ">=" 
        | `EqOp -> "==" | `NeOp -> "=/=") in
      Printf.sprintf "%s %s %s" (translate_exp e1) op_str (translate_exp e2)

  | CallE (id, args) -> 
      let arg_strs = List.map translate_arg args in
      Printf.sprintf "%s(%s)" id.it (String.concat ", " arg_strs)
      
  | _ -> "0"

and translate_typ (t : typ) : string =
  match t.it with
  | VarT (id, args) -> 
      if args = [] then id.it 
      else Printf.sprintf "%s(%s)" id.it (String.concat ", " (List.map translate_arg args))
  | BoolT -> "Bool"
  | NumT _ -> "nat"
  | _ -> "WasmType"

and translate_arg (a : arg) : string =
  match a.it with
  | ExpA e -> translate_exp e
  | TypA t -> translate_typ t
  | _ -> "0"

and translate_definition (d : def) : string =
  match d.it with
  | RecD defs -> String.concat "\n" (List.map translate_definition defs)

  | TypD (id, params, insts) ->
      let name = id.it in
      (* [수정] 시그니처를 WasmTerminal로 변경 *)
      let sig_types = String.concat " " (List.map (fun _ -> "WasmTerminal") params) in
      let param_args = String.concat ", " (List.mapi (fun i _ -> Printf.sprintf "N%d" (i + 1)) params) in
      let full_name = if params = [] then name else Printf.sprintf "%s(%s)" name param_args in
      let op_decl = Printf.sprintf "  op %s : %s -> WasmType .\n" name sig_types in
      
      let res = List.map (fun inst ->
        match inst.it with
        | InstD (_, _, deftyp) ->
            (match deftyp.it with
             | AliasT typ ->
                 Printf.sprintf "  eq typecheck(T, %s) = typecheck(T, %s) ." full_name (translate_typ typ)
             | VariantT cases ->
                 let rules = List.map (fun (_, (_, _, prems), _) ->
                   let conds = List.filter_map (fun p -> 
                     match p.it with IfPr e -> Some (translate_exp e) | _ -> None
                   ) prems in
                   if conds = [] then
                     Printf.sprintf "  eq typecheck(i, %s) = true ." full_name
                   else
                     (* 체크 대상 i를 명시하여 ceq 생성 *)
                     Printf.sprintf "  ceq typecheck(i, %s) = true if %s ." full_name (String.concat " /\\ " conds)
                 ) cases in
                 String.concat "\n" rules
             | _ -> "")
      ) insts in
      op_decl ^ String.concat "\n" res

  | DecD (id, params, _, clauses) ->
      let name = id.it in
      let sig_types = String.concat " " (List.map (fun _ -> "WasmTerminal") params) in
      let param_args = String.concat ", " (List.mapi (fun i _ -> Printf.sprintf "N%d" (i + 1)) params) in
      let full_name = if params = [] then name else Printf.sprintf "%s(%s)" name param_args in
      let op_decl = Printf.sprintf "  op %s : %s -> WasmType .\n" name sig_types in
      
      let rules = List.map (fun c ->
        match c.it with
        | DefD (_, _, _, prems) ->
            let conds = List.filter_map (fun p -> 
              match p.it with IfPr e -> Some (translate_exp e) | _ -> None
            ) prems in
            if conds = [] then
              Printf.sprintf "  eq typecheck(i, %s) = true ." full_name
            else
              Printf.sprintf "  ceq typecheck(i, %s) = true if %s ." full_name (String.concat " /\\ " conds)
      ) clauses in
      op_decl ^ String.concat "\n" rules

  | _ -> ""