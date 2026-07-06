val concatn_chunks_result_op : string -> string
val concatn_chunks_inverse_op : string -> string

val fixed_concat2_match_condition :
  string ->
  type_witness:Maude_ir.term ->
  known:Maude_ir.term ->
  left:Maude_ir.term ->
  right:Maude_ir.term ->
  Maude_ir.eq_condition

val materialize_fixed_inverse_concat2 :
  Helper_registry.entry ->
  Helper_request.fixed_inverse_concat2 ->
  Maude_ir.generated list

val materialize_inverse_concatn_chunks :
  Helper_registry.entry ->
  Helper_request.inverse_concatn_chunks ->
  Maude_ir.generated list

val materialize_optional_map_inverse :
  Helper_registry.entry ->
  Helper_request.optional_map_inverse ->
  Maude_ir.generated list
