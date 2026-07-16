val spectec_terminal : Maude_ir.sort
val spectec_terminals : Maude_ir.sort
val spectec_type : Maude_ir.sort
val nat : Maude_ir.sort

val app : string -> Maude_ir.term list -> Maude_ir.term
val concat : Maude_ir.term -> Maude_ir.term -> Maude_ir.term
val generated : string -> Origin.t -> Maude_ir.statement_node -> Maude_ir.generated
val variable_declarations :
  (Maude_ir.statement_node -> Maude_ir.generated) ->
  (string * Maude_ir.type_ref) list ->
  Maude_ir.generated list
val succ : Maude_ir.term -> Maude_ir.term
val not_eps : string -> Maude_ir.eq_condition
