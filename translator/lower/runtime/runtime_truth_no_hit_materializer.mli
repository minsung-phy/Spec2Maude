type complete

type result =
  | Complete of complete
  | Blocked of Diagnostics.t list

val complete_statements : complete -> Maude_ir.generated list
val complete_conditions : complete -> Maude_ir.rule_condition list
val complete_diagnostics : complete -> Diagnostics.t list

val finite_transitive :
  Context.t ->
  helper_name:string ->
  origin:Origin.t ->
  Runtime_truth_decision_helper.request ->
  Runtime_witness_proof.closed_world_domain ->
  result

val acyclic :
  Context.t ->
  helper_name:string ->
  origin:Origin.t ->
  Runtime_truth_decision_helper.request ->
  result
