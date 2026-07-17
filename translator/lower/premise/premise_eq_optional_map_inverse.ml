open Il.Ast
open Maude_ir
open Util.Source

module Request = Helper_request

open Helper_capture
open Premise_result

let source_echo_exp = Premise_diagnostic.source_echo_exp
let vars_subset = Condition_closure.vars_subset
let conditions_bound_vars = Condition_closure.conditions_bound_vars
let with_conditions = Premise_state.with_conditions
let unbound_var_binding = Premise_state.unbound_var_binding
let flat_optional_element_typ = Premise_shape.flat_optional_element_typ

let app name args =
  App (name, args)

let is_opt term =
  app "isOpt" [ term ]

let diagnostics_have_fatal diagnostics =
  List.exists Diagnostics.is_fatal diagnostics

let lower names ctx env ~bound_vars origin _exp known_exp mapped_exp =
  let optional_iter =
    match mapped_exp.it with
    | IterE (body, (Opt, [ generator_id, source_exp ])) ->
      (match
         unbound_var_binding names env ~bound_vars source_exp,
         flat_optional_element_typ source_exp.note,
         flat_optional_element_typ known_exp.note
       with
      | Some (source_id, source_binding), Some source_element_typ, Some _ ->
        (match Expr_translate.carrier_sort_of_typ source_element_typ with
        | Some source_element_sort ->
          Some
            ( body
            , generator_id
            , source_exp
            , source_id
            , source_binding
            , source_element_typ
            , source_element_sort )
        | None -> None)
      | _ -> None)
    | _ -> None
  in
  match optional_iter with
  | None -> None
  | Some
      ( body
      , generator_id
      , source_exp
      , source_id
      , source_binding
      , source_element_typ
      , source_element_sort ) ->
    let source_result = Expr_translate.lower_sequence ctx env origin known_exp in
    (match source_result.term with
    | None -> None
    | Some source_term ->
      let source_bound =
        conditions_bound_vars bound_vars source_result.guards
      in
      if
        (not
           (vars_subset
              (Condition_closure.term_vars source_term)
              source_bound))
        || diagnostics_have_fatal source_result.diagnostics
      then
        None
      else
        let body_source_ids =
          Source_free_vars.exp_and_note_ids body
          |> List.filter (fun id -> id <> generator_id.it)
          |> List.sort_uniq String.compare
        in
        let helper_names =
          Local_name.reserve_sources
            Local_name.empty (generator_id.it :: body_source_ids)
        in
        let helper_head_var =
          Local_name.source_qualified_name
            helper_names generator_id.it (sort_ref source_element_sort)
        in
        let generator_binding =
          { Expr_env.term = Var helper_head_var
          ; sort = source_element_sort
          ; typ = source_element_typ
          }
        in
        let captures =
          body_source_ids
          |> capture_candidates env
          |> make_captures helper_names
        in
        let lower_body captures =
          let helper_env =
            Expr_env.add
              (capture_env captures)
              generator_id.it
              generator_binding
          in
          Expr_translate.lower_value ctx helper_env origin body
        in
        let body_result = lower_body captures in
        (match body_result.term with
        | None -> None
        | Some body_term ->
          let body_used_vars =
            Condition_closure.external_vars_of_term_after_conditions
              [ helper_head_var ]
              body_term
              body_result.guards
          in
          let captures = captures |> filter_used_captures body_used_vars in
          let body_result = lower_body captures in
          (match body_result.term with
          | None -> None
          | Some body_term ->
            let allowed_vars = helper_head_var :: capture_vars captures in
            let body_external =
              Condition_closure.external_vars_of_term_after_conditions
                allowed_vars
                body_term
                body_result.guards
            in
            let helper_bound_after =
              Condition_admissibility.conditions_admissible_bound
                ~constructor_op:
                  (Condition_closure.source_constructor_certificate ctx)
                allowed_vars
                body_result.guards
            in
            if
              diagnostics_have_fatal body_result.diagnostics
              || body_external <> []
              || helper_bound_after = None
              || not (List.mem helper_head_var (Condition_closure.term_vars body_term))
              || not
                   (Condition_closure.is_match_pattern
                      ~constructor_op:
                        (Condition_closure.source_constructor_certificate ctx)
                      body_term)
            then
              None
            else
              let helper_request =
                { Request.kind =
                    Request.Optional_map_inverse
                      { source_shape =
                          { iter_source = source_echo_exp mapped_exp
                          ; body_source = source_echo_exp body
                          ; source_source = source_echo_exp source_exp
                          ; output_typ_source =
                              Il.Print.string_of_typ known_exp.note
                          ; source_typ_source =
                              Il.Print.string_of_typ source_exp.note
                          }
                      ; generator_var = generator_id.it
                      ; helper_head_var
                      ; source_element_sort
                      ; captures
                      ; lowered_body = body_term
                      ; body_eq_conditions = body_result.guards
                      }
                ; reason = "optional IterE inverse binding helper"
                ; origin
                }
              in
              let helper_name =
                Helper.request (Context.helpers ctx) helper_request
              in
              let helper_call =
                app helper_name
                  (source_term
                   :: List.map (fun capture -> capture.Request.call_term) captures)
              in
              let caller_conditions =
                source_result.guards
                @ [ BoolCond (is_opt source_term)
                  ; MatchCond (source_binding.Expr_env.term, helper_call)
                  ]
              in
              if
                Condition_closure.external_vars_of_conditions
                  bound_vars
                  caller_conditions
                <> []
              then
                None
              else
                let result =
                  with_conditions
                    ctx
                    env
                    bound_vars
                    caller_conditions
                    (source_result.diagnostics @ body_result.diagnostics)
                in
                Some
                  { result with
                    env_after =
                      Expr_env.add
                        result.env_after
                        source_id
                        source_binding
                  })))
