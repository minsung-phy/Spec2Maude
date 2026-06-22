val helper_decls :
  has_bits:bool ->
  has_bytes:bool ->
  has_integer_conversion:bool ->
  has_integer_bit_count:bool ->
  has_integer_bitwise:bool ->
  has_integer_shift_rotate:bool ->
  has_integer_narrow:bool ->
  has_integer_average:bool ->
  has_integer_q15:bool ->
  has_rational_integer:bool ->
  string list

val implemented_equations : has_entry:(string -> bool) -> string list
