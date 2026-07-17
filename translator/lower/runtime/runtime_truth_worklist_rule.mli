open Runtime_truth_worklist_core

val lower_head :
  Context.t ->
  item ->
  relation ->
  int ->
  Runtime_truth_scc.rule ->
  Origin.t * Maude_ir.generated list * Diagnostics.t list *
  Runtime_truth_rule_components.head_patterns
