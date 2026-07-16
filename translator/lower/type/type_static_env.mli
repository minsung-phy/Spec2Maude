type static_exp_binding =
  { static_term : Maude_ir.term
  ; static_sort : Maude_ir.sort
  ; static_typ : Il.Ast.typ
  }

type static_env

val empty : static_env
val find_exp : static_env -> string -> static_exp_binding option
val find_typ : static_env -> string -> Maude_ir.term option
val add_exp : static_env -> string -> static_exp_binding -> static_env
val add_typ : static_env -> string -> Maude_ir.term -> static_env
val reserve_static_env : Local_name.t -> static_env -> Local_name.t
val to_expr_env : static_env -> Expr_env.t
