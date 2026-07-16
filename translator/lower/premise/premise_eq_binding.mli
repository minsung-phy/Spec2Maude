val lower_ifpr_eq :
  Local_name.t ->
  Context.t ->
  Expr_env.t ->
  bound_vars:string list ->
  lhs_bound_vars:string list ->
  factor_head_domain:bool ->
  Origin.t ->
  Il.Ast.exp ->
  Il.Ast.exp ->
  Il.Ast.exp ->
  Premise_result.result * Local_name.t
