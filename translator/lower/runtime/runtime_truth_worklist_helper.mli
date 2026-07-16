type mode = Prove | Decide

type request =
  { relation_id : string
  ; specialization : string
  ; input_terms : Maude_ir.term list
  ; input_sorts : Maude_ir.sort list
  ; phase : Runtime_truth_scc.phase
  ; mode : mode
  ; plan : Runtime_truth_scc.t
  }

type invocation =
  { worklist_op : string
  ; proved_op : string
  ; refuted_op : string
  ; lhs : Maude_ir.term
  ; proved_rhs : Maude_ir.term
  ; refuted_rhs : Maude_ir.term
  }

val key : request -> string
val reason : request -> string
val invocation : helper_name:string -> request -> invocation
val true_condition : helper_name:string -> request -> Maude_ir.rule_condition
val false_condition : helper_name:string -> request -> Maude_ir.rule_condition
val surface :
  helper_name:string -> origin:Origin.t -> request -> Maude_ir.generated list
