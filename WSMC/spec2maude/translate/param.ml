open Util.Source
open Il.Ast
open Maude_il


let translate_sort index param =
  match param.it with
  | ExpP (_, typ) -> Term.translate_sort index typ
  | TypP _ -> "SpectecType"
  | DefP (_, params, result) ->
      let sort, _, _ = Prescan.definition_signature index params result in
      sort
  | GramP _ -> invalid_arg "GramP is not supported"


let translate_term index param =
  match param.it with
  | ExpP (id, typ) ->
      Var (Prescan.source_variable index id typ)

  | TypP id ->
      Var (Prescan.source_variable_with_sort index id "SpectecType")

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

let apply_declaration index (parameter : Prescan.definition_parameter) =
  let sort, domain, codomain =
    Prescan.definition_signature
      index parameter.Prescan.params parameter.result
  in
  OpDecl
    { name = "apply"
    ; domain = sort :: domain
    ; codomain
    ; arrow = Total
    ; attrs = []
    }

let definition_value index (value : Prescan.definition_application) =
  let sort, _, _ =
    Prescan.definition_signature index value.params value.result
  in
  OpDecl
    { name = Prescan.def_name index value.target
    ; domain = []
    ; codomain = sort
    ; arrow = Total
    ; attrs = []
    }

let application_equation index
    (application : Prescan.definition_application) =
  let variables =
    application.Prescan.params
    |> translate_sorts index
    |> List.mapi (fun i sort ->
         Var (generated_variable ("APPLY-ARG" ^ string_of_int (i + 1)) sort))
  in
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
         Prescan.definition_signature
           index parameter.Prescan.params parameter.result)
  in
  let applications =
    Prescan.definition_applications index
    |> unique_by (fun (application : Prescan.definition_application) ->
         Prescan.def_name index application.Prescan.target,
         Prescan.definition_signature
           index application.params application.result)
  in
  let values = Prescan.definition_values index in
  let signatures =
    parameters
    @ List.map
        (fun (value : Prescan.definition_application) ->
          ({ id = value.target
           ; params = value.params
           ; result = value.result
           } : Prescan.definition_parameter))
        values
    |> unique_by (fun (parameter : Prescan.definition_parameter) ->
         Prescan.definition_signature
           index parameter.params parameter.result)
  in
  List.concat_map
    (fun (parameter : Prescan.definition_parameter) ->
      let sort, _, _ =
        Prescan.definition_signature index parameter.params parameter.result
      in
      [SortDecl sort; SubsortDecl (sort, "SpectecDef")])
    signatures
  @ List.map (definition_value index) values
  @ List.map (apply_declaration index) signatures
  @ List.map (application_equation index) applications
