open Runtime_truth_worklist_core

val emitted_head_guards :
  Context.t ->
  Maude_ir.term list ->
  Maude_ir.eq_condition list ->
  Maude_ir.eq_condition list

val lower_head :
  Context.t ->
  item ->
  relation ->
  int ->
  Runtime_truth_scc.rule ->
  Origin.t * Maude_ir.generated list * Diagnostics.t list *
  Runtime_truth_rule_components.head_patterns

val lower_head_prefix :
  Context.t ->
  item ->
  relation ->
  int ->
  Runtime_truth_scc.rule ->
  int ->
  Origin.t * Maude_ir.generated list * Diagnostics.t list *
  Runtime_truth_rule_components.head_patterns
