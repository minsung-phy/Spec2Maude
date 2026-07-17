val conditions_admissible_bound :
  ?constructor_op:Condition_pattern_certificate.t ->
  string list -> Maude_ir.eq_condition list -> string list option

val rule_conditions_admissible_bound :
  ?constructor_op:Condition_pattern_certificate.t ->
  string list -> Maude_ir.rule_condition list -> string list option

val helper_call_admissible_after_conditions :
  ?constructor_op:Condition_pattern_certificate.t ->
  string list -> Maude_ir.eq_condition list -> Maude_ir.term list -> bool

val ceq_admissibility_diagnostics :
  ?constructor_op:Condition_pattern_certificate.t ->
  Context.t ->
  Origin.t ->
  Maude_ir.term ->
  Maude_ir.term ->
  Maude_ir.eq_condition list ->
  Diagnostics.t list

val crl_admissibility_diagnostics :
  ?constructor_op:Condition_pattern_certificate.t ->
  Context.t ->
  Origin.t ->
  Maude_ir.term ->
  Maude_ir.term ->
  Maude_ir.rule_condition list ->
  Diagnostics.t list

val typcase_premise_admissibility_diagnostics :
  Context.t ->
  Origin.t ->
  Il.Ast.mixop ->
  string list ->
  Maude_ir.eq_condition list ->
  Diagnostics.t list
