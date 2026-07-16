val lower :
  Local_name.t ->
  Context.t ->
  Expr_env.t ->
  bound_vars:string list ->
  lhs_bound_vars:string list ->
  future_prems:Il.Ast.prem list ->
  factor_head_domains:bool ->
  Origin.t ->
  Il.Ast.exp ->
  Premise_result.result * Local_name.t
