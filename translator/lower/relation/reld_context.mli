type t

val specialize_term : t -> Maude_ir.term -> Maude_ir.term
val specialize_terms : t -> Maude_ir.term list -> Maude_ir.term list
val specialize_guards :
  t -> Maude_ir.eq_condition list -> Maude_ir.eq_condition list
val specialize_conditions :
  t -> Maude_ir.rule_condition list -> Maude_ir.rule_condition list
val membership : t -> Maude_ir.rule_condition
val statements : t -> Maude_ir.generated list

val lower :
  Context.t ->
  Origin.t ->
  Local_name.t ->
  Expr_env.t ->
  Execution_context_certificate.t ->
  t option
