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

val key : request -> string
val reason : request -> string
val decision_op : helper_name:string -> string
val true_op : helper_name:string -> string
val false_op : helper_name:string -> string
val invocation : helper_name:string -> request -> invocation
val true_rewrite_condition :
  helper_name:string -> request -> Maude_ir.rule_condition
val false_rewrite_condition :
  helper_name:string -> request -> Maude_ir.rule_condition
