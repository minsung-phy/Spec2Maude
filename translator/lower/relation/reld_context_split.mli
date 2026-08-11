type t

val lhs_terms : t -> Maude_ir.term list
val condition : t -> Maude_ir.rule_condition
val statements : t -> Maude_ir.generated list

val eliminate_witness_guards :
  t ->
  lhs:Maude_ir.term ->
  rhs:Maude_ir.term ->
  Maude_ir.rule_condition list ->
  Maude_ir.rule_condition list

val lower :
  Context.t ->
  Il.Ast.id ->
  Origin.t ->
  Local_name.t ->
  Expr_env.t ->
  Execution_context_certificate.t ->
  Maude_ir.term list ->
  (t * Local_name.t) option
