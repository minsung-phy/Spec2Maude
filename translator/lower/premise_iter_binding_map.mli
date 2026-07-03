val try_lower :
  lower_body:Premise_iter_support.lower_body ->
  Context.t ->
  Expr_translate.env ->
  bound_vars:string list ->
  Origin.t ->
  prem:Il.Ast.prem ->
  body:Il.Ast.prem ->
  Il.Ast.iter ->
  (Il.Ast.id * Il.Ast.exp) list ->
  Premise_result.result option
