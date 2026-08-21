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

  | TypP id ->
      Var
        { name = String.uppercase_ascii id.it
        ; sort = translate_sort index param
        ; source = false
        }

  | DefP (id, params, result) ->
      Var
        (Prescan.definition_variable index
           ({id; params; result} : Prescan.definition_parameter))

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


let unique_by key values =
  let rec collect seen result = function
    | [] -> List.rev result
    | value :: values ->
        let value_key = key value in
        if List.mem value_key seen then
          collect seen result values
        else
          collect (value_key :: seen) (value :: result) values
  in
  collect [] [] values

let apply_signature index params result =
  translate_sorts index params, Term.translate_sort index result

let apply_declaration index (parameter : Prescan.definition_parameter) =
  let domain, codomain =
    apply_signature index parameter.Prescan.params parameter.result
  in
  OpDecl
    { name = "apply"
    ; domain = "SpectecDef" :: domain
    ; codomain
    ; arrow = Total
    ; attrs = []
    }

let definition_value index id =
  OpDecl
    { name = Prescan.def_name index id
    ; domain = []
    ; codomain = "SpectecDef"
    ; arrow = Total
    ; attrs = []
    }

let application_equation index
    (application : Prescan.definition_application) =
  let variables = translate_terms index application.Prescan.params in
  let target = Prescan.def_name index application.target in
  Eq
    ( App ("apply", Const target :: variables)
    , App (target, variables)
    , []
    )

let translate_applications index =
  let parameters =
    Prescan.definition_parameters index
    |> unique_by (fun (parameter : Prescan.definition_parameter) ->
         apply_signature index parameter.Prescan.params parameter.result)
  in
  let applications =
    Prescan.definition_applications index
    |> unique_by (fun (application : Prescan.definition_application) ->
         Prescan.def_name index application.Prescan.target,
         apply_signature index application.params application.result)
  in
  List.map (definition_value index) (Prescan.definition_values index)
  @ List.map (apply_declaration index) parameters
  @ List.map (application_equation index) applications
