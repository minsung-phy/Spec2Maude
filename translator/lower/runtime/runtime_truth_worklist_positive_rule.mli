val lower :
  Context.t ->
  Runtime_truth_worklist_core.item ->
  Runtime_truth_worklist_core.relation list ->
  Runtime_truth_worklist_core.relation ->
  int ->
  Runtime_truth_scc.rule ->
  Maude_ir.generated list * Diagnostics.t list
