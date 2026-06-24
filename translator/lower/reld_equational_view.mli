val relation_has_maude_equational_view :
  Context.t ->
  Il.Ast.id ->
  bool

val translate :
  Context.t ->
  Origin.t ->
  Il.Ast.id ->
  Relation_shape.execution_shape ->
  Il.Ast.rule list ->
  Reld_common.output
