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

let enabled_sort name =
  sort ("RuntimeEnabledness" ^ name ^ "Conf")

let frozen_all sorts =
  match sorts with
  | [] -> []
  | _ ->
    let rec range index = function
      | [] -> []
      | _ :: rest -> index :: range (index + 1) rest
    in
    [ Frozen (range 1 sorts) ]

let helper_surface item =
  let request = item.request in
  let result_sort = enabled_sort item.name in
  let enabled_op =
    Runtime_enabledness_helper.enabled_op ~helper_name:item.name
  in
  let true_op =
    Runtime_enabledness_helper.true_op ~helper_name:item.name
  in
  let false_op =
    Runtime_enabledness_helper.false_op ~helper_name:item.name
  in
  [ generated item.name item.origin (sort_decl result_sort)
  ; generated
      item.name
      item.origin
      (op
         enabled_op
         (List.map sort_ref request.input_sorts)
         result_sort
         ~attrs:(frozen_all request.input_sorts))
  ; generated item.name item.origin (op true_op [] result_sort ~attrs:[ Ctor ])
  ; generated item.name item.origin (op false_op [] result_sort ~attrs:[ Ctor ])
  ]

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
    |> Condition_closure.normalize_rule_conditions [ lhs ]
  in
  let diagnostics =
    Condition_closure.crl_admissibility_diagnostics
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

let false_rule ctx item =
  let request = item.request in
  match request.runtime_search_requests, request.runtime_truth_decisions with
  | [], [ decision ]
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
      |> Condition_closure.normalize_rule_conditions [ lhs ]
    in
    let diagnostics =
      Condition_closure.crl_admissibility_diagnostics
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
  | _ -> None, []

let unsupported ctx item =
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin:item.origin
    ~constructor:"RuntimeEnabledness/materializer/false-unimplemented"
    ~enclosing:(Context.enclosing_path ctx)
    ~profile:(Context.profile_name ctx)
    ~reason:
      "otherwise predecessor enabledness needs a source-complete false decision, but this materializer currently exposes only the typed enabledness decision surface"
    ~suggestion:
      "Implement a total enabledness decision from the predecessor source premises before relying on this ElsePr branch; do not encode failed search as false"
    ~source_echo:(Runtime_enabledness_helper.reason item.request)
    ()

let materialize_item ctx item =
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
  { statements = helper_surface item @ true_statements
                 @ false_statements
  ; diagnostics =
      true_diagnostics
      @ false_diagnostics
      @ (if false_missing then [ unsupported ctx item ] else [])
  }

let append left right =
  { statements = left.statements @ right.statements
  ; diagnostics = left.diagnostics @ right.diagnostics
  }

let materialize ctx items =
  items
  |> List.map (materialize_item ctx)
  |> List.fold_left append { statements = []; diagnostics = [] }
