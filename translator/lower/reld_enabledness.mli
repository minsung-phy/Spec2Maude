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
  Il.Ast.rule list ->
  Reld_common.output * Maude_ir.rule_condition list
