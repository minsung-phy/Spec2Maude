open Il.Ast
open Maude_il

(* 타입 이름 *)
let rec translate_term typ =
  match typ.it with
  | VarT (id, args) -> App (id.it, List.map Arg.translate_term args)
  | BoolT -> Const "bool"
  | NumT numtyp -> Const (Xl.Num.string_of_typ numtyp)
  | TextT -> Const "text"
  | TupT _ -> invalid_arg "TupT must be translated by translate_components"
  | IterT (typ, _) -> translate_term typ

(* 그 타입의 값을 담을 Maude sort *)
let rec translate_sort typ =
  match typ.it with
  | NumT `NatT -> "Nat"
  | NumT `IntT -> "Int"
  | IterT _ -> "SpectecTerminals"
  | VarT _
  | BoolT
  | NumT (`RatT | `RealT)
  | TextT
  | TupT _ -> "SpectecTerminal"

let translate_conditions translate_count value typ =
  match typ.it with
  | IterT (element_typ, iter) -> 
      Iter.translate_conditions translate_count value (translate_term element_typ) iter
  | _ -> [BoolCond (App ("typecheck", [value; translate_term typ]))]

(* constructor 인자 하나 *)
let make_component translate_count name typ =
  let sort = translate_sort typ in
  let value = Var {name; sort} in
  let condition = translate_conditions translate_count value typ in value, sort, conditions

(* TupT 또는 타입 하나를 constructor 인자로 분해 *)
let translate_components translate_count typ =
  match typ.it with
  | TupT fields -> 
      fields |> List.mapi (fun index (id, typ) ->
                            let name =
                              if id.it = "_" then
                                "VALUE" ^ string_of_int (index + 1)
                              else
                                String.uppercase_ascii id.it
                            in make_component translate_count name typ)

  | _ -> [make_component translate_count "VALUE" typ]