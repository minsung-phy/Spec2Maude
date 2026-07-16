type result =
  { statements : Maude_ir.generated list
  ; conditions : Maude_ir.rule_condition list
  ; diagnostics : Diagnostics.t list
  }

val materialize :
  Context.t ->
  helper_name:string ->
  origin:Origin.t ->
  Runtime_truth_decision_helper.request ->
  result
