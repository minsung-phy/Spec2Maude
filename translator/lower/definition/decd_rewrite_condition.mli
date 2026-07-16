type term_result =
  { term : Maude_ir.term
  ; conditions : Maude_ir.rule_condition list
  ; diagnostics : Diagnostics.t list
  }

val lower_term :
  Context.t -> Origin.t -> Local_name.t -> Maude_ir.term ->
  term_result * Local_name.t

val lower_eq_conditions :
  Context.t ->
  Origin.t ->
  Local_name.t ->
  Maude_ir.eq_condition list ->
  Maude_ir.rule_condition list * Diagnostics.t list * Local_name.t

val lower_rule_conditions :
  Context.t ->
  Origin.t ->
  Local_name.t ->
  Maude_ir.rule_condition list ->
  Maude_ir.rule_condition list * Diagnostics.t list * Local_name.t
