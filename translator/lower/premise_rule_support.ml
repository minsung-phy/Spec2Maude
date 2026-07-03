open Maude_ir

let app name args =
  App (name, args)

let relation_call rel_id inputs =
  App (Naming.relation_op rel_id, inputs)

let relation_equational_view_call rel_id inputs =
  App (Naming.relation_equational_view_op rel_id, inputs)

let fresh_result_var ~fallback ~label origin (rel_id : Il.Ast.id) sort =
  let seed =
    String.concat
      "-"
      [ label; rel_id.it; Origin.source_location origin; Origin.path origin ]
  in
  Var (Naming.maude_var ~fallback seed ^ ":" ^ sort_name sort)

let lower_input_values ctx env origin exps =
  let results =
    exps |> List.map (Expr_translate.lower_value ctx env origin)
  in
  let terms =
    results
    |> List.filter_map (fun (result : Expr_translate.result) -> result.term)
  in
  let guards =
    results
    |> List.map (fun (result : Expr_translate.result) -> result.guards)
    |> List.concat
  in
  let diagnostics =
    results
    |> List.map (fun (result : Expr_translate.result) -> result.diagnostics)
    |> List.concat
  in
  if List.length terms = List.length exps then
    Some terms, guards, diagnostics
  else
    None, guards, diagnostics

let sequence_of_terms = function
  | [] -> Const "eps"
  | hd :: tl -> List.fold_left (fun acc term -> app "_ _" [ acc; term ]) hd tl

let is_sequence_sort sort =
  sort_name sort = "SpectecTerminals"

let tuple_component_pattern component term =
  match Expr_translate.carrier_sort_of_typ component.Relation_shape.typ with
  | Some sort when is_sequence_sort sort -> Some (app "seq" [ term ]), []
  | Some _ -> Some term, []
  | None ->
    None,
    [ "could not determine the Maude carrier for output component type `"
      ^ Il.Print.string_of_typ component.Relation_shape.typ
      ^ "`"
    ]

let tuple_pattern_from_components components terms =
  let rec collect patterns errors components terms =
    match components, terms with
    | [], [] -> List.rev patterns, List.rev errors
    | component :: components, term :: terms ->
      let pattern, new_errors = tuple_component_pattern component term in
      let patterns =
        match pattern with
        | None -> patterns
        | Some pattern -> pattern :: patterns
      in
      collect patterns (List.rev_append new_errors errors) components terms
    | _ :: _, [] | [], _ :: _ ->
      List.rev patterns,
      List.rev
        ("output component/term arity mismatch while building annotated relation tuple pattern"
         :: errors)
  in
  let patterns, errors = collect [] [] components terms in
  if errors <> [] then
    None, errors
  else
    Some (app "tuple" [ sequence_of_terms patterns ]), []

let result_output_condition bound pattern subject =
  let pattern_vars = Condition_closure.term_vars pattern in
  if Condition_closure.is_match_pattern pattern then
    MatchCond (pattern, subject)
  else if Condition_closure.vars_subset pattern_vars bound then
    EqCond (pattern, subject)
  else
    MatchCond (pattern, subject)
