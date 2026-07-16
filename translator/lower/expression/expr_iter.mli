open Il.Ast

type callbacks =
  { lower_value : Context.t -> Expr_env.t -> Origin.t -> exp -> Expr_result.result
  ; lower_sequence : Context.t -> Expr_env.t -> Origin.t -> exp -> Expr_result.result
  }

val lower_iter :
  callbacks ->
  Context.t ->
  Expr_env.t ->
  Origin.t ->
  exp ->
  exp ->
  iterexp ->
  Expr_result.result
