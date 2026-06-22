open Il.Ast

type callbacks =
  { lower_value : Context.t -> Expr_support.env -> Origin.t -> exp -> Expr_support.result
  ; lower_iter :
      Context.t ->
      Expr_support.env ->
      Origin.t ->
      exp ->
      exp ->
      iterexp ->
      Expr_support.result
  }

val lower_tuple_component :
  callbacks -> Context.t -> Expr_support.env -> Origin.t -> exp -> Expr_support.result

val lower_tuple :
  callbacks -> Context.t -> Expr_support.env -> Origin.t -> exp -> exp list -> Expr_support.result

val lower_list :
  callbacks -> Context.t -> Expr_support.env -> Origin.t -> exp -> exp list -> Expr_support.result

val lower_sequence :
  callbacks -> Context.t -> Expr_support.env -> Origin.t -> exp -> Expr_support.result

val lower_cat :
  callbacks -> Context.t -> Expr_support.env -> Origin.t -> exp -> exp -> exp -> Expr_support.result

val lower_opt :
  callbacks -> Context.t -> Expr_support.env -> Origin.t -> exp -> exp option -> Expr_support.result

val lower_lift :
  callbacks -> Context.t -> Expr_support.env -> Origin.t -> exp -> exp -> Expr_support.result
