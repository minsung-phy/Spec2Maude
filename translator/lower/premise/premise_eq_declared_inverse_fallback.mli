val lower :
  Context.t ->
  Expr_env.t ->
  bound_vars:string list ->
  Origin.t ->
  Il.Ast.exp ->
  Il.Ast.exp ->
  Il.Ast.exp ->
  Premise_result.result option
