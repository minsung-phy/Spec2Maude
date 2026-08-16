open Util.Source
open Il.Ast
open Maude_il

let translate_term translate_exp translate_typ arg =
  match arg.it with
  | ExpA exp ->
      translate_exp exp

  | TypA typ ->
      translate_typ typ

  | DefA id -> 
      Const id.it

  | GramA _ ->
      invalid_arg "GramA is not translated"
