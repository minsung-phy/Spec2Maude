open Il.Ast

type callbacks =
  { lower_value :
      Context.t ->
      Expr_env.t ->
      Origin.t ->
      exp ->
      Expr_result.result
  ; witness_of_typ :
      Context.t ->
      Expr_env.t ->
      Origin.t ->
      typ ->
      Maude_ir.term option * Diagnostics.t list
  }

val lower :
  callbacks ->
  Context.t ->
  Expr_env.t ->
  Origin.t ->
  exp ->
  exp ->
  typ ->
  typ ->
  Expr_result.result
