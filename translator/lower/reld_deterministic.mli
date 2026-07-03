val translate :
  Context.t ->
  Origin.t ->
  Il.Ast.id ->
  Analysis.Relation_graph.relation_kind ->
  Il.Ast.mixop ->
  Relation_shape.deterministic_shape ->
  Il.Ast.rule list ->
  Reld_common.output
