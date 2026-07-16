val try_lower :
  Local_name.t ->
  lower_body:(
    Local_name.t ->
    Context.t ->
    Expr_env.t ->
    bound_vars:string list ->
    Origin.t ->
    Il.Ast.prem ->
    Premise_result.result * Local_name.t) ->
  Context.t ->
  Expr_env.t ->
  bound_vars:string list ->
  Origin.t ->
  prem:Il.Ast.prem ->
  body:Il.Ast.prem ->
  Il.Ast.iter ->
  (Il.Ast.id * Il.Ast.exp) list ->
  (Premise_result.result * Local_name.t) option
