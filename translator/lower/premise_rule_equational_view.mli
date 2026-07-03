val lower :
  Context.t ->
  Expr_translate.env ->
  bound_vars:string list ->
  Origin.t ->
  Il.Ast.prem ->
  Il.Ast.id ->
  Il.Ast.exp ->
  Relation_shape.execution_shape ->
  Premise_result.result
