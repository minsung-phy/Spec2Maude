val transitive_edge :
  static_validation_premise:(Context.t -> Il.Ast.prem -> bool) ->
  external_validation_guards:
    (Context.t ->
     Expr_env.t ->
     Maude_ir.term list ->
     Origin.t ->
     Il.Ast.prem list ->
     Premise_result.outcome) ->
  ctx:Context.t ->
  item:Runtime_truth_worklist_core.item ->
  relations:Runtime_truth_worklist_core.relation list ->
  relation:Runtime_truth_worklist_core.relation ->
  rule:Runtime_truth_scc.rule ->
  identity:Runtime_truth_worklist_indexed.identity ->
  transitive:Runtime_witness_proof.transitive_domain ->
  head_env:Expr_env.t ->
  head_terms:Maude_ir.term list ->
  history:Maude_ir.term ->
  prove_mode:bool ->
  (Runtime_truth_worklist_indexed.result * Diagnostics.t list)
  Runtime_truth_worklist_core.edge_result
