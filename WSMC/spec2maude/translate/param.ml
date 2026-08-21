open Util.Source
open Il.Ast
open Maude_il


let translate_sort index param =
  match param.it with
  | ExpP (_, typ) -> Term.translate_sort index typ
  | TypP _ -> "SpectecType"
  | DefP _ -> "SpectecDef"
  | GramP _ -> invalid_arg "GramP is not supported"


let translate_term index param =
  match param.it with
  | ExpP (id, typ) ->
      Var (Prescan.source_variable index id typ)

  | TypP id
  | DefP (id, _, _) ->
      Var
        { name = String.uppercase_ascii id.it
        ; sort = translate_sort index param
        ; source = false
        }

  | GramP _ ->
      invalid_arg "GramP is not supported"


let translate_sorts index params =
  List.map (translate_sort index) params

let translate_terms index params =
  List.map (translate_term index) params


let translate_eq_conditions index params =
  params
  |> List.concat_map (fun param ->
       match param.it with
       | ExpP (_, typ) ->
           Term.translate_typ_conditions index (translate_term index param) typ

       | TypP _
       | DefP _ ->
           []

       | GramP _ ->
           invalid_arg "GramP is not supported")
