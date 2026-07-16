val lower :
  Local_name.t ->
  Context.t ->
  Expr_env.t ->
  bound_vars:string list ->
  factor_head_domain:bool ->
  Origin.t ->
  Il.Ast.prem ->
  Il.Ast.id ->
  Il.Ast.exp ->
  Relation_shape.deterministic_shape ->
  Premise_result.result * Local_name.t
