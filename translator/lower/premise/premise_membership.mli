val try_lower_ifpr_meme_binding :
  Local_name.t ->
  Context.t ->
  Expr_env.t ->
  bound_vars:string list ->
  future_prems:Il.Ast.prem list ->
  Origin.t ->
  Il.Ast.exp ->
  Il.Ast.exp ->
  Il.Ast.exp ->
  Premise_result.result option * Local_name.t
