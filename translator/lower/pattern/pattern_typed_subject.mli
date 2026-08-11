type t
type value

val deterministic_output :
  output_typ:Il.Ast.typ -> pattern:Il.Ast.exp -> t option

val lower_equality_value :
  Context.t -> Expr_env.t -> Origin.t -> Il.Ast.exp -> value

val value_result : value -> Expr_result.result
val equality_value : value:value -> pattern:Il.Ast.exp -> t option
val matches_result : t -> Expr_result.result -> bool

val lower_pattern_named :
  t ->
  Local_name.t ->
  Context.t ->
  Expr_env.t ->
  Origin.t ->
  Il.Ast.exp ->
  Expr_result.pattern_result * Local_name.t
