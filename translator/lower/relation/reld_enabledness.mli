val complement :
  Context.t ->
  Origin.t ->
  Il.Ast.id ->
  Analysis.Relation_graph.relation_kind ->
  Il.Ast.mixop ->
  Relation_shape.execution_shape ->
  Maude_ir.sort list ->
  Origin.t ->
  Maude_ir.term list ->
  Maude_ir.eq_condition list ->
  Il.Ast.rule list ->
  Reld_result.output * Maude_ir.rule_condition list list
