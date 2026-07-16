module Request = Helper_request

type blocker =
  | False_support of Runtime_truth_false_support.blocker
  | Structural of
      { origin : Origin.t
      ; constructor : string
      ; reason : string
      ; source_echo : string option
      }

type t =
  | Complete of Maude_ir.rule_condition list
  | Blocked of
      { diagnostics : Diagnostics.t list
      ; blockers : blocker list
      }

let blocker_reason = function
  | False_support blocker ->
    Runtime_truth_false_support.blocker_reason blocker
  | Structural blocker -> blocker.reason

let blocker_diagnostic ctx = function
  | False_support blocker ->
    Runtime_truth_false_support.diagnostic ctx blocker
  | Structural blocker ->
    Diagnostics.make
      ~category:Diagnostics.Unsupported
      ~origin:blocker.origin
      ~constructor:blocker.constructor
      ~enclosing:
        (Diagnostic_provenance.enclosing
           ~context:(Context.enclosing_path ctx) blocker.origin)
      ~profile:(Context.profile_name ctx)
      ~reason:blocker.reason
      ~suggestion:
        "Keep the dependent false edge blocked until its source components and total decision request are structurally available"
      ?source_echo:blocker.source_echo
      ()

let structural origin constructor reason source_echo =
  Structural { origin; constructor; reason; source_echo }

let truth_request_for_false ctx rel_id input_terms input_sorts =
  let plan = Runtime_predicate_search.truth_plan ctx rel_id in
  match
    Runtime_predicate_search.truth_helper_request
      ~input_terms ~input_sorts plan
  with
  | Some request -> Some request
  | None ->
    (match
       Analysis.Function_graph.runtime_predicate_truth_plan
         (Context.function_graph ctx) rel_id
     with
    | Analysis.Function_graph.Runtime_search_no_shape_blockers
        { closure; rules } ->
      Some
        { Runtime_truth_search_helper.rel_id
        ; input_terms
        ; input_sorts
        ; recursion = Runtime_truth_search_helper.Acyclic
        ; closure
        ; rules
        }
    | Runtime_search_blocked_plan _ -> None)

let lower ctx origin env ~rel_id ~components =
  let lowered =
    Runtime_truth_rule_components.lower_value_components
      ctx
      env
      origin
      components
  in
  if List.exists Diagnostics.is_fatal lowered.diagnostics then
    Blocked
      { diagnostics = lowered.diagnostics
      ; blockers =
          [ structural origin
              "RuntimeTruthDependentFalse/RulePr/component-lowering"
              "dependent RulePr components retained a fatal lowering diagnostic"
              None
          ]
      }
  else
    match
      lowered.values
    with
    | Some (terms, sorts) ->
      (match
         truth_request_for_false ctx rel_id terms sorts
       with
      | None ->
        Blocked
          { diagnostics = []
          ; blockers =
              [ structural origin
                  "RuntimeTruthDependentFalse/RulePr/truth-request"
                  ("dependent relation `"
                   ^ rel_id
                   ^ "` does not have a runtime truth request for false refutation")
                  None
              ]
          }
      | Some truth_request ->
        (match
           Runtime_truth_false_support.check_truth_request
             ctx
             truth_request
        with
        | Runtime_truth_false_support.Blocked blockers ->
          Blocked
            { diagnostics = []
            ; blockers = List.map (fun blocker -> False_support blocker) blockers
            }
        | Runtime_truth_false_support.Supported ->
          let truth_name =
            Helper.request
              (Context.helpers ctx)
              { Request.kind =
                  Request.Runtime_predicate_truth_search truth_request
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
              { Request.kind =
                  Request.Runtime_predicate_truth_decision decision_request
              ; reason = Runtime_truth_decision_helper.reason decision_request
              ; origin
              }
          in
          Complete
            (List.map
               (fun condition -> Maude_ir.EqCondition condition)
               lowered.guards
             @ [ Runtime_truth_decision_helper.false_rewrite_condition
                   ~helper_name:decision_name
                   decision_request
               ])))
    | None ->
      Blocked
        { diagnostics = lowered.diagnostics
        ; blockers =
            [ structural origin
                "RuntimeTruthDependentFalse/RulePr/unbound-components"
                "dependent RulePr components did not lower to already-bound Maude values"
                None
            ]
        }
