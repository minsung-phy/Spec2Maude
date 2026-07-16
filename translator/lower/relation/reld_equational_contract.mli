val validate :
  Context.t ->
  Origin.t ->
  Il.Ast.id ->
  Relation_shape.execution_shape ->
  Il.Ast.rule list ->
  Diagnostics.t list
