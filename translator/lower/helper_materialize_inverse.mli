val pair_split_result_op : string -> string
val pair_split_unzip_op : string -> string
val concatn_chunks_result_op : string -> string
val concatn_chunks_inverse_op : string -> string

val materialize_inverse_pair_split :
  Helper_registry.entry ->
  Helper_request.inverse_pair_split ->
  Maude_ir.generated list

val materialize_inverse_concatn_chunks :
  Helper_registry.entry ->
  Helper_request.inverse_concatn_chunks ->
  Maude_ir.generated list

val materialize_optional_map_inverse :
  Helper_registry.entry ->
  Helper_request.optional_map_inverse ->
  Maude_ir.generated list
