open Maude_ir
open Util.Source

module Request = Helper_request

open Helper_capture
open Premise_result

let app name args = App (name, args)

let is_opt term =
  app "isOpt" [ term ]

let lower_ifpr_opt
    ctx env ~bound_vars origin ~prem ~body ~source_generator ~source_exp =
  let unsupported_optional_iter reason =
    Premise_diagnostic.unsupported
      ~ctx ~origin ~constructor:"Premise/IterPr/OptIf"
      ~source_echo:(Premise_diagnostic.source_echo_prem prem)
      ~reason
      ~suggestion:
        "Keep this IterPr Unsupported until the optional premise helper can preserve absent/present branches source-safely"
      ()
  in
  match Premise_shape.flat_optional_element_typ source_exp.note with
  | None ->
    { (empty_with_env ~bound_vars env) with
      diagnostics =
        [ unsupported_optional_iter
            ("optional IfPr IterPr requires a flat optional source; source note is `"
             ^ Il.Print.string_of_typ source_exp.note
             ^ "`")
        ]
    }
  | Some source_element_typ ->
    (match Expr_translate.carrier_sort_of_typ source_element_typ with
    | None ->
      { (empty_with_env ~bound_vars env) with
        diagnostics =
          [ unsupported_optional_iter
              "optional IfPr IterPr could not determine a Maude carrier for the optional element type"
          ]
      }
    | Some source_element_sort ->
      let source_result = Expr_translate.lower_sequence ctx env origin source_exp in
      (match source_result.term with
      | None ->
        { (empty_with_env ~bound_vars env) with
          eq_conditions = source_result.guards
        ; diagnostics = source_result.diagnostics
        }
      | Some source_term ->
        let source_bound =
          Condition_closure.conditions_bound_vars bound_vars source_result.guards
        in
        if
          not
            (Condition_closure.vars_subset
               (Condition_closure.term_vars source_term)
               source_bound)
        then
          { (empty_with_env ~bound_vars env) with
            eq_conditions = source_result.guards
          ; diagnostics =
              source_result.diagnostics
              @ [ unsupported_optional_iter
                    "optional premise source is not bound before the helper call; emitting a Bool helper condition would create a Maude used-before-bound variable"
                ]
          }
        else
          let body_source_ids =
            Source_free_vars.exp_and_note_ids body
            |> List.filter (fun id -> id <> source_generator.it)
            |> List.sort_uniq String.compare
          in
          let helper_names =
            Local_name.reserve_sources
              Local_name.empty (source_generator.it :: body_source_ids)
          in
          let helper_head_var =
            Local_name.source_qualified_name
              helper_names source_generator.it (sort_ref source_element_sort)
          in
          let source_tail_var, helper_names =
            Local_name.fresh_qualified_name
              helper_names Local_name.Tail
              (sort_ref (sort "SpectecTerminals"))
          in
          let body_result_var, helper_names =
            Local_name.fresh_qualified_name
              helper_names Local_name.Output (sort_ref (sort "Bool"))
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
          let helper_env =
            Expr_env.add
              (capture_env captures)
              source_generator.it
              generator_binding
          in
          let body_result =
            Expr_translate.lower_bool_condition ctx helper_env origin body
          in
          (match body_result.term with
          | None ->
            { (empty_with_env ~bound_vars env) with
              eq_conditions = source_result.guards
            ; diagnostics = source_result.diagnostics @ body_result.diagnostics
            }
          | Some _ ->
            let body_vars =
              match body_result.term with
              | Some term ->
                Condition_closure.external_vars_of_term_after_conditions
                  [ helper_head_var; body_result_var ]
                  term
                  body_result.guards
              | None -> []
            in
            let captures = captures |> filter_used_captures body_vars in
            let allowed_vars = helper_head_var :: capture_vars captures in
            let variable_diagnostics =
            if Condition_closure.vars_subset body_vars allowed_vars then
                []
              else
                [ unsupported_optional_iter
                    "optional premise body references variables outside the helper head and captured closure variables"
                ]
            in
            (match body_result.term, variable_diagnostics with
            | Some lowered_body, [] ->
              let helper_request =
                { Request.kind =
                    Request.Iter_premise_opt_bool
                      { source_shape =
                          { prem_source = Premise_diagnostic.source_echo_prem prem
                          ; body_source = Premise_diagnostic.source_echo_exp body
                          ; source_source = Premise_diagnostic.source_echo_exp source_exp
                          ; source_typ_source = Il.Print.string_of_typ source_exp.note
                          }
                      ; generator_var = source_generator.it
                      ; helper_head_var
                      ; source_tail_var
                      ; body_result_var
                      ; source_element_sort
                      ; captures
                      ; lowered_body
                      ; body_eq_conditions = body_result.guards
                      }
                ; reason = "optional IfPr IterPr Bool helper"
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
                @ [ EqCond (is_opt source_term, Const "true")
                  ; BoolCond helper_call
                  ]
              in
              let caller_bound =
                Condition_closure.conditions_bound_vars
                  bound_vars caller_conditions
              in
              let helper_missing_vars =
                Condition_closure.term_vars helper_call
                |> List.filter (fun var -> not (List.mem var caller_bound))
                |> List.sort_uniq String.compare
              in
              if helper_missing_vars = [] then
                Premise_state.with_conditions
                  ctx
                  env
                  bound_vars
                  caller_conditions
                  (source_result.diagnostics @ body_result.diagnostics)
              else
                { (empty_with_env ~bound_vars env) with
                  eq_conditions = source_result.guards
                ; diagnostics =
                    source_result.diagnostics @ body_result.diagnostics
                    @ [ unsupported_optional_iter
                          ("optional premise helper call contains variables that are not bound by earlier premise conditions: "
                           ^ String.concat ", " helper_missing_vars)
                      ]
                }
            | _ ->
              { (empty_with_env ~bound_vars env) with
                eq_conditions = source_result.guards
              ; diagnostics =
                  source_result.diagnostics @ body_result.diagnostics
                  @ variable_diagnostics
              }))))
