val translate :
  Context.t ->
  Origin.t ->
  Il.Ast.id ->
  Analysis.Relation_graph.relation_kind ->
  Il.Ast.mixop ->
  string ->
  Relation_shape.component list ->
  Il.Ast.rule list ->
  Reld_result.output
