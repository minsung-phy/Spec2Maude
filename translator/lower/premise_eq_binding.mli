val lower_ifpr_eq :
  Context.t ->
  Expr_translate.env ->
  bound_vars:string list ->
  Origin.t ->
  Il.Ast.exp ->
  Il.Ast.exp ->
  Il.Ast.exp ->
  Premise_result.result
