open Maude_ir

type item =
  { name : string
  ; origin : Origin.t
  ; request : Runtime_truth_decision_helper.request
  }

type result =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

let generated name origin node =
  Maude_ir.generated ~provenance:(Maude_ir.Helper name) ~origin node

let decision_sort name =
  sort ("RuntimeTruthDecision" ^ name ^ "Conf")

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
  let result_sort = decision_sort item.name in
  let decision_op =
    Runtime_truth_decision_helper.decision_op ~helper_name:item.name
  in
  let true_op =
    Runtime_truth_decision_helper.true_op ~helper_name:item.name
  in
  let false_op =
    Runtime_truth_decision_helper.false_op ~helper_name:item.name
  in
  let input_sorts = request.truth_request.input_sorts in
  [ generated item.name item.origin (sort_decl result_sort)
  ; generated
      item.name
      item.origin
      (op
         decision_op
         (List.map sort_ref input_sorts)
         result_sort
         ~attrs:(frozen_all input_sorts))
  ; generated item.name item.origin (op true_op [] result_sort ~attrs:[ Ctor ])
  ; generated item.name item.origin (op false_op [] result_sort ~attrs:[ Ctor ])
  ]

let true_rule ctx item =
  let call =
    Runtime_truth_decision_helper.invocation ~helper_name:item.name item.request
  in
  let truth_condition =
    Runtime_truth_search_helper.rewrite_condition
      ~helper_name:item.request.truth_helper_name
      item.request.truth_request
  in
  let conditions =
    [ truth_condition ]
    |> Condition_closure.normalize_rule_conditions [ call.lhs ]
  in
  let diagnostics =
    Condition_closure.crl_admissibility_diagnostics
      ctx
      item.origin
      call.lhs
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
             ~label:(item.name ^ "-decision-true")
             call.lhs
             call.true_rhs
             conditions)
      ]
    , diagnostics )

let false_rule ctx item =
  let call =
    Runtime_truth_decision_helper.invocation ~helper_name:item.name item.request
  in
  let refutation =
    Runtime_truth_decision_refutation.materialize
      ctx
      ~helper_name:item.name
      ~origin:item.origin
      item.request
  in
  if List.exists Diagnostics.is_fatal refutation.diagnostics then
    [], [], refutation.diagnostics
  else
    let conditions =
      refutation.conditions
      |> Condition_closure.normalize_rule_conditions [ call.lhs ]
    in
    match conditions with
    | [] -> [], refutation.statements, refutation.diagnostics
    | _ ->
      let diagnostics =
        Condition_closure.crl_admissibility_diagnostics
          ctx
          item.origin
          call.lhs
          call.false_rhs
          conditions
      in
      if List.exists Diagnostics.is_fatal diagnostics then
        [], [], refutation.diagnostics @ diagnostics
      else
        ( [ generated
              item.name
              item.origin
              (crl
                 ~label:(item.name ^ "-decision-false")
                 call.lhs
                 call.false_rhs
                 conditions)
          ]
        , refutation.statements
        , refutation.diagnostics @ diagnostics )

let unsupported_false ctx item =
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin:item.origin
    ~constructor:"RuntimeTruthDecision/materializer/false-unimplemented"
    ~enclosing:(Context.enclosing_path ctx)
    ~profile:(Context.profile_name ctx)
    ~reason:
      "runtime truth decision needs a source-complete false proof, but the refuter did not produce a usable false rule"
    ~suggestion:
      "Do not emit a partial truth decision surface; implement a source-complete no-hit/refutation helper before using runtimeTruthFalse"
    ~source_echo:(Runtime_truth_decision_helper.reason item.request)
    ()

let materialize_item ctx item =
  let true_statements, true_diagnostics = true_rule ctx item in
  let false_statements, refutation_statements, false_diagnostics =
    false_rule ctx item
  in
  let false_missing =
    match false_statements with
    | [] -> true
    | _ :: _ -> false
  in
  let diagnostics =
    true_diagnostics
    @ false_diagnostics
    @ (if false_missing then [ unsupported_false ctx item ] else [])
  in
  if false_missing || List.exists Diagnostics.is_fatal diagnostics then
    { statements = []; diagnostics }
  else
    { statements =
        helper_surface item @ true_statements
        @ refutation_statements @ false_statements
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
