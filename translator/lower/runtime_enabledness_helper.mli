type truth_decision =
  { helper_name : string
  ; request : Runtime_truth_decision_helper.request
  }

type request =
  { relation_id : string
  ; rule_id : string option
  ; call_terms : Maude_ir.term list
  ; predecessor_terms : Maude_ir.term list
  ; input_sorts : Maude_ir.sort list
  ; lhs_conditions : Maude_ir.eq_condition list
  ; premise_eq_conditions : Maude_ir.eq_condition list
  ; premise_rule_conditions : Maude_ir.rule_condition list
  ; runtime_search_requests : Runtime_search_helper.request list
  ; runtime_truth_search_requests : Runtime_truth_search_helper.request list
  ; runtime_truth_decisions : truth_decision list
  ; source_echo : string option
  }

type invocation =
  { enabled_op : string
  ; true_op : string
  ; false_op : string
  ; lhs : Maude_ir.term
  ; true_rhs : Maude_ir.term
  ; false_rhs : Maude_ir.term
  }

val key : request -> string
val reason : request -> string
val enabled_op : helper_name:string -> string
val true_op : helper_name:string -> string
val false_op : helper_name:string -> string
val invocation : helper_name:string -> request -> invocation
val false_rewrite_condition :
  helper_name:string -> request -> Maude_ir.rule_condition
