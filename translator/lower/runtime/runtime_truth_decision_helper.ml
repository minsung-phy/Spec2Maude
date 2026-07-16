type request =
  { truth_helper_name : string
  ; truth_request : Runtime_truth_search_helper.request
  }

type invocation =
  { decision_op : string
  ; true_op : string
  ; false_op : string
  ; lhs : Maude_ir.term
  ; true_rhs : Maude_ir.term
  ; false_rhs : Maude_ir.term
  }

let key request =
  Runtime_truth_search_helper.key request.truth_request

let reason request =
  "runtime predicate truth decision for "
  ^ Runtime_truth_search_helper.reason request.truth_request

let decision_op ~helper_name =
  helper_name

let true_op ~helper_name =
  Naming.helper_companion ~role:"truth-true" helper_name

let false_op ~helper_name =
  Naming.helper_companion ~role:"truth-false" helper_name

let invocation ~helper_name request =
  let decision_op = decision_op ~helper_name in
  let true_op = true_op ~helper_name in
  let false_op = false_op ~helper_name in
  { decision_op
  ; true_op
  ; false_op
  ; lhs = Maude_ir.App (decision_op, request.truth_request.input_terms)
  ; true_rhs = Maude_ir.Const true_op
  ; false_rhs = Maude_ir.Const false_op
  }

let true_rewrite_condition ~helper_name request =
  let call = invocation ~helper_name request in
  Maude_ir.RewriteCond (call.lhs, call.true_rhs)

let false_rewrite_condition ~helper_name request =
  let call = invocation ~helper_name request in
  Maude_ir.RewriteCond (call.lhs, call.false_rhs)

let surface ~helper_name ~origin request =
  let open Maude_ir in
  let generated node =
    generated ~provenance:(Helper helper_name) ~origin node
  in
  let result =
    sort ("RuntimeTruthDecision" ^ Naming.sort_token helper_name ^ "Conf")
  in
  let input_sorts = request.truth_request.input_sorts in
  let frozen =
    match input_sorts with
    | [] -> []
    | sorts -> [ Frozen (List.mapi (fun index _ -> index + 1) sorts) ]
  in
  let call = invocation ~helper_name request in
  [ generated (sort_decl result)
  ; generated
      (op call.decision_op (List.map sort_ref input_sorts) result ~attrs:frozen)
  ; generated (op call.true_op [] result ~attrs:[ Ctor ])
  ; generated (op call.false_op [] result ~attrs:[ Ctor ])
  ]
