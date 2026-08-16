open Il.Ast
open Maude_il


(* SpecTec iteration -> Maude conditions *)

let length value = App ("len", [value])

let typecheck value element_type = BoolCond (App ("typecheck", [value; element_type]))

let translate_conditions translate_count value element_type iter =
  let check = typecheck value element_type in
  match iter with
  | Opt ->
      [check; BoolCond (App ("_<=_", [length value; Const "1"]))]
  | List ->
      [check]
  | List1 ->
      [check; BoolCond (App ("_<_", [Const "0"; length value]))]
  | ListN (count, _) ->
      [check; EqCond (length value, translate_count count)]
