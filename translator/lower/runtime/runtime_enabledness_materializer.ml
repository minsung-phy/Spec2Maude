open Maude_ir

type item =
  { name : string
  ; origin : Origin.t
  ; request : Runtime_enabledness_helper.request
  }

type result =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

let generated name origin node =
  Maude_ir.generated ~provenance:(Maude_ir.Helper name) ~origin node

let helper_surface item =
  Runtime_enabledness_helper.surface
    ~helper_name:item.name ~origin:item.origin item.request

let pattern_certificate ctx item =
  let request = item.request in
  let worklists =
    request.runtime_truth_worklist_decisions
    |> List.concat_map (fun
         (decision : Runtime_truth_worklist_enabledness.decision) ->
      Runtime_truth_worklist_helper.surface
        ~helper_name:decision.positive_helper_name ~origin:item.origin
        decision.positive_request
      @ Runtime_truth_worklist_helper.surface
          ~helper_name:decision.total_helper_name ~origin:item.origin
          decision.total_request)
  in
  Condition_pattern_certificate.union
    (Condition_closure.source_constructor_certificate ctx)
    (Condition_pattern_certificate.generated (helper_surface item @ worklists))

let rule_condition_of_eq condition =
  EqCondition condition

let true_rule ctx item =
  let request = item.request in
  let call = Runtime_enabledness_helper.invocation ~helper_name:item.name request in
  let lhs =
    App (call.enabled_op, request.predecessor_terms)
  in
  let conditions =
    List.map rule_condition_of_eq request.lhs_conditions
    @ request.premise_rule_conditions
    @ List.map rule_condition_of_eq request.premise_eq_conditions
    |> Condition_closure.normalize_rule_conditions
         ~constructor_op:(pattern_certificate ctx item)
         [ lhs ]
  in
  let diagnostics =
    Condition_closure.crl_admissibility_diagnostics
      ~constructor_op:(pattern_certificate ctx item)
      ctx
      item.origin
      lhs
      call.true_rhs
      conditions
  in
  if List.exists Diagnostics.is_fatal diagnostics then
    [], diagnostics
  else
    ( [ generated
          item.name
          item.origin
          (crl
             ~label:(item.name ^ "-enabled-true")
             lhs
             call.true_rhs
             conditions)
      ]
    , diagnostics )

let expected_truth_conditions request =
  request.Runtime_enabledness_helper.runtime_truth_decisions
  |> List.map (fun decision ->
    Runtime_truth_search_helper.rewrite_condition
      ~helper_name:
        decision.Runtime_enabledness_helper.request.truth_helper_name
      decision.request.truth_request)

let expected_worklist_conditions request =
  request.Runtime_enabledness_helper.runtime_truth_worklist_decisions
  |> List.map Runtime_truth_worklist_enabledness.positive_condition

let false_rule ctx item =
  let request = item.request in
  match
    ( request.runtime_search_requests
    , request.runtime_truth_decisions
    , request.runtime_truth_worklist_decisions )
  with
  | [], [ decision ]
    , []
    when request.premise_rule_conditions = expected_truth_conditions request ->
    let call = Runtime_enabledness_helper.invocation ~helper_name:item.name request in
    let lhs = App (call.enabled_op, request.predecessor_terms) in
    let decision_condition =
      Runtime_truth_decision_helper.false_rewrite_condition
        ~helper_name:decision.helper_name
        decision.request
    in
    let conditions =
      List.map rule_condition_of_eq request.lhs_conditions
      @ List.map rule_condition_of_eq request.premise_eq_conditions
      @ [ decision_condition ]
      |> Condition_closure.normalize_rule_conditions
           ~constructor_op:(pattern_certificate ctx item)
           [ lhs ]
    in
    let diagnostics =
      Condition_closure.crl_admissibility_diagnostics
        ~constructor_op:(pattern_certificate ctx item)
        ctx
        item.origin
        lhs
        call.false_rhs
        conditions
    in
    if List.exists Diagnostics.is_fatal diagnostics then
      None, diagnostics
    else
      ( Some
          (generated
             item.name
             item.origin
             (crl
                ~label:(item.name ^ "-enabled-false")
                lhs
                call.false_rhs
                conditions))
      , diagnostics )
  | [], [], [ decision ]
    when request.premise_eq_conditions = []
         && request.premise_rule_conditions = expected_worklist_conditions request ->
    let call = Runtime_enabledness_helper.invocation ~helper_name:item.name request in
    let lhs = App (call.enabled_op, request.predecessor_terms) in
    let conditions =
      List.map rule_condition_of_eq request.lhs_conditions
      @ List.map rule_condition_of_eq request.premise_eq_conditions
      @ [ Runtime_truth_worklist_enabledness.false_condition decision ]
      |> Condition_closure.normalize_rule_conditions
           ~constructor_op:(pattern_certificate ctx item)
           [ lhs ]
    in
    let diagnostics =
      Condition_closure.crl_admissibility_diagnostics
        ~constructor_op:(pattern_certificate ctx item)
        ctx item.origin lhs call.false_rhs conditions
    in
    if List.exists Diagnostics.is_fatal diagnostics then None, diagnostics
    else
      ( Some
          (generated item.name item.origin
             (crl ~label:(item.name ^ "-enabled-false")
                lhs call.false_rhs conditions))
      , diagnostics )
  | _ -> None, []

let unsupported ctx item =
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin:item.origin
    ~constructor:"RuntimeEnabledness/materializer/false-unimplemented"
    ~enclosing:
      (Diagnostic_provenance.enclosing
         ~context:(Context.enclosing_path ctx) item.origin)
    ~profile:(Context.profile_name ctx)
    ~reason:
      "otherwise predecessor enabledness needs a source-complete false decision, but this materializer currently exposes only the typed enabledness decision surface"
    ~suggestion:
      "Implement a total enabledness decision from the predecessor source premises before relying on this ElsePr branch; do not encode failed search as false"
    ~source_echo:(Runtime_enabledness_helper.reason item.request)
    ()

let legacy_equation_blocker ctx item =
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin:item.origin
    ~constructor:
      "RuntimeEnabledness/materializer/legacy-truth-equation-order"
    ~enclosing:
      (Diagnostic_provenance.enclosing
         ~context:(Context.enclosing_path ctx) item.origin)
    ~profile:(Context.profile_name ctx)
    ~reason:
      "legacy runtime-truth enabledness cannot coexist with equational premise conditions: its true branch would reorder the rewrite before equations and its false branch has no source-ordered prefix-success/current-equation-failure alternatives"
    ~suggestion:
      "Keep this predecessor Unsupported, or route recursive/transitive truth through the SCC worklist engine with a certified ordered mixed-condition decision"
    ~source_echo:(Runtime_enabledness_helper.reason item.request)
    ()

let materialize_item ctx item =
  let request = item.request in
  if request.runtime_truth_decisions <> []
     && request.runtime_truth_worklist_decisions = []
     && request.premise_eq_conditions <> []
  then
    { statements = []; diagnostics = [ legacy_equation_blocker ctx item ] }
  else
  let true_statements, true_diagnostics = true_rule ctx item in
  let false_statement, false_diagnostics = false_rule ctx item in
  let false_statements =
    match false_statement with
    | None -> []
    | Some statement -> [ statement ]
  in
  let false_missing =
    match false_statement with
    | None -> true
    | Some _ -> false
  in
  let diagnostics =
    true_diagnostics
    @ false_diagnostics
    @ (if false_missing then [ unsupported ctx item ] else [])
  in
  if false_missing || List.exists Diagnostics.is_fatal diagnostics then
    { statements = []; diagnostics }
  else
    { statements = helper_surface item @ true_statements @ false_statements
    ; diagnostics
    }

let append left right =
  { statements = left.statements @ right.statements
  ; diagnostics = left.diagnostics @ right.diagnostics
  }

let materialize ctx items =
  items
  |> List.map (materialize_item ctx)
  |> List.fold_left append { statements = []; diagnostics = [] }
