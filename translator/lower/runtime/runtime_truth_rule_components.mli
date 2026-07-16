type head_patterns =
  { terms : Maude_ir.term list option
  ; env : Expr_env.t
  ; guards : Maude_ir.eq_condition list
  ; diagnostics : Diagnostics.t list
  ; local_names : Local_name.t
  }

type value_components =
  { values : (Maude_ir.term list * Maude_ir.sort list) option
  ; guards : Maude_ir.eq_condition list
  ; diagnostics : Diagnostics.t list
  }

val local_rules :
  Runtime_truth_decision_helper.request ->
  Analysis.Function_graph.runtime_search_rule list

val child_origin :
  Origin.t ->
  string ->
  string ->
  Util.Source.region ->
  string option ->
  Origin.t

val exp_components : Il.Ast.exp -> Il.Ast.exp list

val lower_complete_head_patterns :
  Local_name.t ->
  ?env:Expr_env.t ->
  Context.t ->
  Origin.t ->
  Il.Ast.exp list ->
  head_patterns

val lower_partial_head_patterns_for_acyclic_refutation :
  Local_name.t ->
  ?env:Expr_env.t ->
  Context.t ->
  Origin.t ->
  Il.Ast.exp list ->
  head_patterns

val lower_value_components :
  Context.t ->
  Expr_env.t ->
  Origin.t ->
  Il.Ast.exp list ->
  value_components
