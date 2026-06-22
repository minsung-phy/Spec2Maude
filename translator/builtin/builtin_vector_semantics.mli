val helper_decls :
  has_float_rep:bool ->
  has_num_bytes:bool ->
  has_storage_const_bytes:bool ->
  has_lanes:bool ->
  string list

val implemented_equations : has_entry:(string -> bool) -> string list
