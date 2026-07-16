type result =
  | Materialized of Reld_result.output * Maude_ir.rule_condition list
  | Blocked of Diagnostics.t list
  | Not_applicable

val complement :
  Context.t ->
  rel_origin:Origin.t ->
  relation_id:Il.Ast.id ->
  relation_kind:Analysis.Relation_graph.relation_kind ->
  relation_mixop:Il.Ast.mixop ->
  Relation_shape.execution_shape ->
  input_sorts:Maude_ir.sort list ->
  origin:Origin.t ->
  current_lhs_terms:Maude_ir.term list ->
  previous_rules:Il.Ast.rule list ->
  result
