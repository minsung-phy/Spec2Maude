open Runtime_truth_worklist_core

type positive_children =
  { env : Expr_env.t
  ; eq_conditions : Maude_ir.eq_condition list
  ; rule_conditions : Maude_ir.rule_condition list
  ; diagnostics : Diagnostics.t list
  ; statements : Maude_ir.generated list
  ; complete : bool
  }

val recursive_call :
  Context.t ->
  item ->
  relation list ->
  Expr_env.t ->
  Maude_ir.term ->
  Runtime_truth_scc.premise ->
  bool ->
  (Maude_ir.rule_condition * Maude_ir.eq_condition list * Diagnostics.t list)
  option

val indexed_edge :
  Context.t ->
  item ->
  relation list ->
  Origin.t ->
  Runtime_truth_worklist_indexed.identity ->
  Expr_env.t ->
  Maude_ir.term ->
  Il.Ast.prem ->
  Runtime_truth_worklist_indexed.result option * Diagnostics.t list

val forall_edge :
  Context.t ->
  item ->
  relation list ->
  Origin.t ->
  Runtime_truth_worklist_indexed.identity ->
  Expr_env.t ->
  Maude_ir.term ->
  Il.Ast.prem ->
  Runtime_truth_scc.premise list ->
  Runtime_truth_worklist_indexed.result option * Diagnostics.t list

val lower_positive_children :
  Context.t ->
  item ->
  relation list ->
  Origin.t ->
  Runtime_truth_worklist_indexed.phase ->
  int ->
  Maude_ir.term list ->
  Expr_env.t ->
  Maude_ir.term ->
  (int * Runtime_truth_scc.premise) list ->
  positive_children
