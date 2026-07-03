val materialize_iter_map :
  Helper_registry.entry -> Helper_request.iter_map -> Maude_ir.generated list
val materialize_iter_zip_map :
  Helper_registry.entry -> Helper_request.iter_zip_map -> Maude_ir.generated list
val materialize_iter_listn :
  Helper_registry.entry -> Helper_request.iter_listn -> Maude_ir.generated list
val materialize_iter_listn_source :
  Helper_registry.entry ->
  Helper_request.iter_listn_source ->
  Maude_ir.generated list
val materialize_iter_premise_opt_bool :
  Helper_registry.entry ->
  Helper_request.iter_premise_opt_bool ->
  Maude_ir.generated list
val materialize_iter_premise_list_bool :
  Helper_registry.entry ->
  Helper_request.iter_premise_list_bool ->
  Maude_ir.generated list
val materialize_iter_premise_exists_bool :
  Helper_registry.entry ->
  Helper_request.iter_premise_exists_bool ->
  Maude_ir.generated list
val materialize_iter_premise_zip_bool :
  Helper_registry.entry ->
  Helper_request.iter_premise_zip_bool ->
  Maude_ir.generated list
val materialize_iter_pattern_zip :
  Helper_registry.entry ->
  Helper_request.iter_pattern_zip ->
  Maude_ir.generated list
