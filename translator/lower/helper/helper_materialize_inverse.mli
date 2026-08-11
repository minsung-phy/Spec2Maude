val decode_chunks_result_op : string -> string
val decode_chunks_op : string -> string
val decode_chunks_result_constructor : string -> Origin.t -> Maude_ir.generated
val unzip2_result_constructor : string -> Origin.t -> Maude_ir.generated

val unzip2_match_condition :
  string ->
  chunks:Maude_ir.term ->
  left:Maude_ir.term ->
  right:Maude_ir.term ->
  Maude_ir.eq_condition

val materialize_unzip2 :
  Helper_registry.entry ->
  Helper_request.unzip2 ->
  Maude_ir.generated list

val materialize_decode_chunks :
  Helper_registry.entry ->
  Helper_request.decode_chunks ->
  Maude_ir.generated list

val materialize_optional_map_inverse :
  Helper_registry.entry ->
  Helper_request.optional_map_inverse ->
  Maude_ir.generated list
