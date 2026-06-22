val helper_decls :
  has_float_sign:bool ->
  has_float_rep:bool ->
  has_float_exact:bool ->
  string list

val implemented_equations : has_entry:(string -> bool) -> string list
