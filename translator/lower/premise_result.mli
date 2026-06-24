type result =
  { eq_conditions : Maude_ir.eq_condition list
  ; rule_conditions : Maude_ir.rule_condition list
  ; has_else : bool
  ; let_bound_ids : string list list
  ; env_after : Expr_translate.env
  ; bound_vars_after : string list
  ; diagnostics : Diagnostics.t list
  }

val normalize_vars : string list -> string list

val empty_with_env :
  ?bound_vars:string list ->
  Expr_translate.env ->
  result

val empty : result
val append : result -> result -> result
