type error =
  | Diagnostics of Diagnostics.t list
  | Blocked of string list

let lower ctx origin env ~rel_id ~components =
  let lowered =
    Runtime_truth_rule_components.lower_value_components
      ctx
      env
      origin
      components
  in
  if List.exists Diagnostics.is_fatal lowered.diagnostics then
    Error (Diagnostics lowered.diagnostics)
  else
    match
      lowered.values, Runtime_predicate_search.truth_plan ctx rel_id
    with
    | Some (terms, sorts), truth_plan ->
      (match
         Runtime_predicate_search.truth_helper_request
           ~input_terms:terms
           ~input_sorts:sorts
           truth_plan
       with
      | None ->
        Error
          (Blocked
             [ "dependent relation `"
               ^ rel_id
               ^ "` does not have a runtime truth request for false refutation"
             ])
      | Some truth_request ->
        (match
           Runtime_truth_decision_false_support.check_truth_request
             ctx
             truth_request
         with
        | Runtime_truth_decision_false_support.Blocked blockers ->
          Error (Blocked blockers)
        | Runtime_truth_decision_false_support.Supported ->
          let truth_name =
            Helper.request
              (Context.helpers ctx)
              { Helper.kind =
                  Helper.Runtime_predicate_truth_search truth_request
              ; reason = Runtime_truth_search_helper.reason truth_request
              ; origin
              }
          in
          let decision_request =
            { Runtime_truth_decision_helper.truth_helper_name = truth_name
            ; truth_request
            }
          in
          let decision_name =
            Helper.request
              (Context.helpers ctx)
              { Helper.kind =
                  Helper.Runtime_predicate_truth_decision decision_request
              ; reason = Runtime_truth_decision_helper.reason decision_request
              ; origin
              }
          in
          Ok
            (List.map
               (fun condition -> Maude_ir.EqCondition condition)
               lowered.guards
             @ [ Runtime_truth_decision_helper.false_rewrite_condition
                   ~helper_name:decision_name
                   decision_request
               ])))
    | None, _ ->
      Error
        (Blocked
           [ "dependent RulePr components did not lower to already-bound Maude values"
           ])
