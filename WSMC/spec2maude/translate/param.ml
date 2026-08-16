open Util.Source
open Il.Ast
open Maude_il


let translate_sort param =
  match param.it with
  | ExpP (_, typ) -> Term.translate_sort typ
  | TypP _ -> "SpectecType"
  | DefP _ -> "SpectecDef"
  | GramP _ -> invalid_arg "GramP is not supported"


let translate_term param =
  match param.it with
  | ExpP (id, _)
  | TypP id
  | DefP (id, _, _) ->
      Var
        { name = String.uppercase_ascii id.it
        ; sort = translate_sort param
        }

  | GramP _ ->
      invalid_arg "GramP is not supported"


let translate_sorts params =
  List.map translate_sort params

let translate_terms params =
  List.map translate_term params


let translate_eq_conditions params =
  params
  |> List.concat_map (fun param ->
       match param.it with
       | ExpP (_, typ) ->
           Term.translate_typ_conditions (translate_term param) typ

       | TypP _
       | DefP _ ->
           []

       | GramP _ ->
           invalid_arg "GramP is not supported")
