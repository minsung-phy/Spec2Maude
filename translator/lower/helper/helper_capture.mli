val capture_candidates :
  Expr_env.t -> string list -> (string * Expr_env.binding) list

val available_capture_candidates :
  Expr_env.t -> string list -> (string * Expr_env.binding) list

val required_capture_candidates :
  Expr_env.t ->
  required_vars:string list ->
  string list ->
  (string * string * Expr_env.binding) list

val captured_vars :
  (string * string * Expr_env.binding) list -> string list

val missing_required_vars :
  required_vars:string list ->
  captured_vars:string list ->
  string list

val make_required_captures :
  Local_name.t ->
  (string * string * Expr_env.binding) list ->
  Helper_request.capture list

val make_captures :
  Local_name.t ->
  (string * Expr_env.binding) list ->
  Helper_request.capture list

val capture_vars : Helper_request.capture list -> string list
val capture_env : Helper_request.capture list -> Expr_env.t
val filter_used_captures :
  string list -> Helper_request.capture list -> Helper_request.capture list
val filter_captures_by_call_vars :
  string list -> Helper_request.capture list -> Helper_request.capture list
