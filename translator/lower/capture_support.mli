val source_free_var_ids : Il.Ast.exp -> string list
val type_note_free_var_ids : Il.Ast.typ -> string list
val source_and_note_free_var_ids : Il.Ast.exp -> string list
val prem_free_var_ids : Il.Ast.prem -> string list

val helper_local_stem : Origin.t -> string -> string

val capture_candidates :
  Expr_support.env -> string list -> (string * Expr_support.binding) list

val required_capture_candidates :
  Expr_support.env ->
  required_vars:string list ->
  string list ->
  (string * string * Expr_support.binding) list

val captured_vars :
  (string * string * Expr_support.binding) list -> string list

val missing_required_vars :
  required_vars:string list ->
  captured_vars:string list ->
  string list

val make_required_captures :
  string -> (string * string * Expr_support.binding) list -> Helper.capture list

val make_captures :
  string -> (string * Expr_support.binding) list -> Helper.capture list

val capture_vars : Helper.capture list -> string list
val capture_env : Helper.capture list -> Expr_support.env
val filter_used_captures : string list -> Helper.capture list -> Helper.capture list
