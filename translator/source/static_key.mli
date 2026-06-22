type env

type typ_ref =
  { category_id : string
  ; static_args_key : string option
  }

val empty : env
val of_static_typ_env : (string * Il.Ast.typ) list -> env
val of_params_args : Il.Ast.param list -> Il.Ast.arg list -> (env, string) result
val of_arg : ?env:env -> Il.Ast.arg -> string
val of_args : ?env:env -> Il.Ast.arg list -> string option
val of_typ : ?env:env -> Il.Ast.typ -> string option
val typ_ref : ?env:env -> Il.Ast.typ -> typ_ref option
