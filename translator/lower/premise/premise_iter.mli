type lower_body =
  Local_name.t ->
  Context.t ->
  Expr_env.t ->
  bound_vars:string list ->
  Origin.t ->
  Il.Ast.prem ->
  Premise_result.result * Local_name.t

val lower :
  Local_name.t ->
  lower_body:lower_body ->
  discharge_static_validation:bool ->
  Context.t ->
  Expr_env.t ->
  bound_vars:string list ->
  future_prems:Il.Ast.prem list ->
  escape_source_ids:string list ->
  Origin.t ->
  prem:Il.Ast.prem ->
  body:Il.Ast.prem ->
  Il.Ast.iterexp ->
  Premise_result.result * Local_name.t
