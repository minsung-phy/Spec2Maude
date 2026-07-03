type lower_body =
  Expr_translate.env ->
  bound_vars:string list ->
  Origin.t ->
  Il.Ast.prem ->
  Premise_result.result

val lower :
  lower_body:lower_body ->
  Context.t ->
  Expr_translate.env ->
  bound_vars:string list ->
  future_prems:Il.Ast.prem list ->
  escape_source_ids:string list ->
  Origin.t ->
  prem:Il.Ast.prem ->
  body:Il.Ast.prem ->
  Il.Ast.iterexp ->
  Premise_result.result
