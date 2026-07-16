open Il.Ast

type callbacks =
  { lower_value : Context.t -> Expr_env.t -> Origin.t -> exp -> Expr_result.result
  ; lower_iter :
      Context.t ->
      Expr_env.t ->
      Origin.t ->
      exp ->
      exp ->
      iterexp ->
      Expr_result.result
  }

val lower_tuple_component :
  callbacks -> Context.t -> Expr_env.t -> Origin.t -> exp -> Expr_result.result

val lower_tuple :
  callbacks -> Context.t -> Expr_env.t -> Origin.t -> exp -> exp list -> Expr_result.result

val lower_list :
  callbacks -> Context.t -> Expr_env.t -> Origin.t -> exp -> exp list -> Expr_result.result

val lower_sequence :
  callbacks -> Context.t -> Expr_env.t -> Origin.t -> exp -> Expr_result.result

val lower_cat :
  callbacks -> Context.t -> Expr_env.t -> Origin.t -> exp -> exp -> exp -> Expr_result.result

val lower_opt :
  callbacks -> Context.t -> Expr_env.t -> Origin.t -> exp -> exp option -> Expr_result.result

val lower_lift :
  callbacks -> Context.t -> Expr_env.t -> Origin.t -> exp -> exp -> Expr_result.result
