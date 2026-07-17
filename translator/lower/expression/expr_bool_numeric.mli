open Il.Ast
open Maude_ir

type callbacks =
  { lower_value : Context.t -> Expr_env.t -> Origin.t -> exp -> Expr_result.result
  ; lower_sequence : Context.t -> Expr_env.t -> Origin.t -> exp -> Expr_result.result
  ; lower_call :
      Context.t -> Expr_env.t -> Origin.t -> exp -> id -> arg list -> Expr_result.result
  ; witness_of_typ :
      Context.t ->
      Expr_env.t ->
      Origin.t ->
      typ ->
      term option * Diagnostics.t list
  }

val lower_numeric_conversion :
  callbacks -> Context.t -> Expr_env.t -> Origin.t -> exp -> exp -> numtyp -> numtyp -> Expr_result.result

val lower_bool_value :
  callbacks -> Context.t -> Expr_env.t -> Origin.t -> exp -> Expr_result.result

val lower_unary_value :
  callbacks -> Context.t -> Expr_env.t -> Origin.t -> exp -> unop -> exp -> Expr_result.result

val lower_binary_value :
  callbacks -> Context.t -> Expr_env.t -> Origin.t -> exp -> binop -> exp -> exp -> Expr_result.result

val lower_numeric_guard_value :
  callbacks -> Context.t -> Expr_env.t -> Origin.t -> exp -> Expr_result.result

val lower_bool_raw :
  callbacks -> Context.t -> Expr_env.t -> Origin.t -> exp -> Expr_result.result

val lower_mem_value :
  callbacks -> Context.t -> Expr_env.t -> Origin.t -> exp -> exp -> exp -> Expr_result.result

val lower_mem_raw :
  callbacks -> Context.t -> Expr_env.t -> Origin.t -> exp -> exp -> exp -> Expr_result.result
