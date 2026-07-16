type item =
  { name : string
  ; origin : Origin.t
  ; request : Runtime_truth_worklist_helper.request
  }

type complete

type result =
  | Complete_result of complete
  | Blocked_result of Diagnostics.t list

val complete_statements : complete -> Maude_ir.generated list
val complete_diagnostics : complete -> Diagnostics.t list

val materialize : Context.t -> item list -> result
