open Il.Ast

type callbacks =
  { lower_value : Context.t -> Expr_support.env -> Origin.t -> exp -> Expr_support.result
  ; lower_sequence : Context.t -> Expr_support.env -> Origin.t -> exp -> Expr_support.result
  }

val lower_iter :
  callbacks ->
  Context.t ->
  Expr_support.env ->
  Origin.t ->
  exp ->
  exp ->
  iterexp ->
  Expr_support.result
