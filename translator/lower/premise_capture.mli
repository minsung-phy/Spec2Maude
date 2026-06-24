val source_and_note_free_var_ids : Il.Ast.exp -> string list
val prem_free_var_ids : Il.Ast.prem -> string list
val helper_local_stem : Origin.t -> string -> string

val capture_candidates :
  Expr_translate.env -> string list -> (string * Expr_translate.binding) list

val make_captures :
  string -> (string * Expr_translate.binding) list -> Helper.capture list

val capture_vars : Helper.capture list -> string list
val capture_env : Helper.capture list -> Expr_translate.env
val filter_used_captures : string list -> Helper.capture list -> Helper.capture list
