open Il.Ast
open Maude_ir
open Util.Source

let vars_subset = Condition_closure.vars_subset
let conditions_bound_vars = Condition_closure.conditions_bound_vars
let with_conditions = Premise_state.with_conditions
let binding_is_bound = Premise_state.binding_is_bound
let unbound_var_binding = Premise_state.unbound_var_binding

let app name args =
  App (name, args)

let result_has_fatal (result : Expr_translate.result) =
  List.exists Diagnostics.is_fatal result.diagnostics

let lower_projection_binding_value ctx env origin exp =
  let numeric_result =
    Expr_translate.lower_numeric_guard_value ctx env origin exp
  in
  if numeric_result.term <> None && not (result_has_fatal numeric_result) then
    numeric_result
  else
    Expr_translate.lower_value ctx env origin exp

let inverse_numeric_conversion_exp value_exp source_numtyp target_numtyp =
  { value_exp with
    it = CvtE (value_exp, target_numtyp, source_numtyp)
  ; note = { value_exp.note with it = NumT source_numtyp }
  }

let projection_binding_sides projection_exp value_exp =
  match projection_exp.it with
  | CvtE (inner_projection, source_numtyp, target_numtyp) ->
    ( inner_projection
    , inverse_numeric_conversion_exp value_exp source_numtyp target_numtyp )
  | _ -> projection_exp, value_exp

let lower_unary_projection ctx env ~bound_vars origin _exp projection_exp value_exp =
  let projection_exp, value_exp =
    projection_binding_sides projection_exp value_exp
  in
  match projection_exp.it with
  | ProjE (({ it = UncaseE (scrutinee_exp, _mixop); _ } as _uncase_exp), 0) ->
    (match scrutinee_exp.it with
    | VarE scrutinee_id ->
      (match Expr_translate.find_var env scrutinee_id.it with
      | Some scrutinee_binding when not (binding_is_bound bound_vars scrutinee_binding) ->
        (match lower_projection_binding_value ctx env origin projection_exp with
        | { term = Some (App (projection_op, [ scrutinee_term ])); guards = projection_guards; diagnostics = projection_diagnostics } ->
          (match
             Constructor_registry.lookup_unary_projection
               (Context.constructors ctx)
               ~projection_op
           with
          | Constructor_registry.Projection_found entry ->
            let value_result =
              lower_projection_binding_value ctx env origin value_exp
            in
            (match value_result.term with
            | Some value_term ->
              let prefix_conditions = value_result.guards in
              (match
                 Condition_closure.conditions_admissible_bound
                   bound_vars
                   prefix_conditions
               with
              | None -> None
              | Some bound_after_prefix ->
                if
                  vars_subset
                    (Condition_closure.term_vars value_term)
                    bound_after_prefix
                then (
                  let match_condition =
                    MatchCond
                      ( scrutinee_term
                      , app entry.Constructor_registry.constructor_op [ value_term ] )
                  in
                  let conditions =
                    prefix_conditions @ [ match_condition ] @ projection_guards
                  in
                  let env_after =
                    Expr_translate.add_var
                      env
                      scrutinee_id.it
                      scrutinee_binding
                  in
                  Some
                    (with_conditions
                       env_after
                       bound_vars
                       conditions
                       (projection_diagnostics @ value_result.diagnostics)))
                else
                  None)
            | None -> None)
          | Constructor_registry.Projection_missing
          | Constructor_registry.Projection_ambiguous _ -> None)
        | _ -> None)
      | Some _ | None -> None)
    | _ -> None)
  | _ -> None

let is_raw_numeric_sort sort =
  match sort_name sort with
  | "Nat" | "Int" | "Rat" -> true
  | _ -> false

let lower_direct_binding_value ctx env origin target_binding value_exp =
  let value_result =
    if sort_name target_binding.Expr_translate.sort = "SpectecTerminals" then
      Expr_translate.lower_sequence ctx env origin value_exp
    else
      Expr_translate.lower_value ctx env origin value_exp
  in
  match value_result.term with
  | Some _ -> value_result
  | None when is_raw_numeric_sort target_binding.Expr_translate.sort ->
    let numeric_result =
      Expr_translate.lower_numeric_guard_value ctx env origin value_exp
    in
    (match numeric_result.term with
    | Some _ -> numeric_result
    | None -> value_result)
  | None -> value_result

let lower_direct_var ctx env ~bound_vars origin _exp target_exp value_exp =
  let target_exp, value_exp =
    projection_binding_sides target_exp value_exp
  in
  match unbound_var_binding env ~bound_vars target_exp with
  | None -> None
  | Some (target_id, target_binding) ->
    if not (Condition_closure.is_match_pattern target_binding.term) then
      None
    else
      let value_result =
        lower_direct_binding_value ctx env origin target_binding value_exp
      in
      (match value_result.term with
      | Some value_term ->
        let prefix_bound =
          conditions_bound_vars bound_vars value_result.guards
        in
        if vars_subset (Condition_closure.term_vars value_term) prefix_bound then
          let env_after =
            Expr_translate.add_var env target_id target_binding
          in
          Some
            (with_conditions
               env_after
               bound_vars
               (value_result.guards @ [ MatchCond (target_binding.term, value_term) ])
               value_result.diagnostics)
        else
          None
      | None -> None)
