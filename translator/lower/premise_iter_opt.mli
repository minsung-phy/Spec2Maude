val lower_ifpr_opt :
  Context.t ->
  Expr_translate.env ->
  bound_vars:string list ->
  Origin.t ->
  prem:Il.Ast.prem ->
  body:Il.Ast.exp ->
  source_generator:Il.Ast.id ->
  source_exp:Il.Ast.exp ->
  Premise_result.result
