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
  "runtimeTruthDecision" ^ helper_name

let true_op ~helper_name =
  "runtimeTruthTrue" ^ helper_name

let false_op ~helper_name =
  "runtimeTruthFalse" ^ helper_name

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
