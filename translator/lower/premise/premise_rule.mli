val lower :
  Local_name.t ->
  Context.t ->
  Expr_env.t ->
  allow_runtime_search:bool ->
  discharge_static_validation:bool ->
  bound_vars:string list ->
  blocked_witness_source_ids:string list ->
  future_prems:Il.Ast.prem list ->
  escape_source_ids:string list ->
  factor_head_domains:bool ->
  Origin.t ->
  Il.Ast.prem ->
  Il.Ast.id ->
  Il.Ast.mixop ->
  Premise_result.result * Local_name.t
