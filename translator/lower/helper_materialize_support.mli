val term_vars : Maude_ir.term -> string list
val schedule_eq_conditions :
  string list -> Maude_ir.eq_condition list -> Maude_ir.eq_condition list option

val spectec_terminal : Maude_ir.sort
val spectec_terminals : Maude_ir.sort
val spectec_type : Maude_ir.sort
val nat : Maude_ir.sort

val app : string -> Maude_ir.term list -> Maude_ir.term
val concat : Maude_ir.term -> Maude_ir.term -> Maude_ir.term
val generated : string -> Origin.t -> Maude_ir.statement_node -> Maude_ir.generated
val helper_call_multi :
  string -> Maude_ir.term list -> Helper_request.capture list -> Maude_ir.term
val helper_call :
  string -> Maude_ir.term -> Helper_request.capture list -> Maude_ir.term
val helper_call_from_tail :
  string -> Helper_request.iter_map -> Maude_ir.term

val not_eps : string -> Maude_ir.eq_condition
val succ : Maude_ir.term -> Maude_ir.term
val result_bound_conditions :
  Helper_request.iter_map -> Maude_ir.eq_condition list
val result_bound_conditions_for :
  initial_bound:string list ->
  body_result_var:string ->
  lowered_body:Maude_ir.term ->
  body_eq_conditions:Maude_ir.eq_condition list ->
  Maude_ir.eq_condition list
val output_item_term :
  Helper_request.iter_map_output_item_shape * string -> Maude_ir.term
val output_item_sort :
  Helper_request.iter_map_output_item_shape -> Maude_ir.sort
val source_item_term :
  Helper_request.iter_map_source_item_shape ->
  Maude_ir.term ->
  Maude_ir.term
