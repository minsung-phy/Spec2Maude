open Runtime_truth_worklist_core

type positive_children =
  { env : Expr_env.t
  ; eq_conditions : Maude_ir.eq_condition list
  ; rule_conditions : Maude_ir.rule_condition list
  ; diagnostics : Diagnostics.t list
  ; statements : Maude_ir.generated list
  ; complete : bool
  }

type 'a edge_result =
  | Materialized of 'a
  | Blocked of Diagnostics.t list

val lower_head :
  Context.t ->
  item ->
  relation ->
  int ->
  Runtime_truth_scc.rule ->
  Origin.t * Maude_ir.generated list * Diagnostics.t list *
  Runtime_truth_rule_components.head_patterns

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

val target_chain :
  Runtime_truth_scc.rule -> Runtime_witness_proof.target_chain option
val transitive_domain :
  Runtime_truth_scc.rule -> Runtime_witness_proof.transitive_domain option
val successor_domain_diagnostics :
  Context.t -> item -> Diagnostics.t list
val seed_rules :
  Context.t ->
  item ->
  relation list ->
  relation ->
  (int * Runtime_truth_scc.rule) list ->
  Runtime_witness_proof.target_chain ->
  Maude_ir.generated list * Diagnostics.t list
val worklist_pattern_certificate :
  Context.t -> item -> relation list -> Condition_pattern_certificate.t
val target_chain_edge :
  Context.t ->
  item ->
  relation list ->
  relation ->
  Runtime_truth_scc.rule ->
  Runtime_witness_proof.target_chain ->
  Expr_env.t ->
  Maude_ir.term list ->
  Maude_ir.term ->
  bool ->
  (Maude_ir.generated list * Maude_ir.rule_condition list list *
   Diagnostics.t list) edge_result
val transitive_edge :
  Context.t ->
  item ->
  relation list ->
  relation ->
  Runtime_truth_scc.rule ->
  Runtime_truth_worklist_indexed.identity ->
  Runtime_witness_proof.transitive_domain ->
  Expr_env.t ->
  Maude_ir.term list ->
  Maude_ir.term ->
  bool ->
  (Runtime_truth_worklist_indexed.result * Diagnostics.t list) edge_result

module Positive_rule : sig
  val lower :
    Context.t ->
    item ->
    relation list ->
    relation ->
    int ->
    Runtime_truth_scc.rule ->
    Maude_ir.generated list * Diagnostics.t list
end
