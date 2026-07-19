type result =
  | Certified
  | Blocked of string

val decide :
  Context.t ->
  Runtime_truth_scc.t ->
  Runtime_truth_worklist_core.relation list ->
  Runtime_truth_worklist_core.relation ->
  Runtime_witness_proof.target_chain ->
  result
