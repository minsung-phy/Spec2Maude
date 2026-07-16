val term_vars : Maude_ir.term -> string list
val is_match_pattern :
  ?constructor_op:Condition_pattern_certificate.t ->
  Maude_ir.term ->
  bool
val source_constructor_certificate : Context.t -> Condition_pattern_certificate.t
val vars_subset : string list -> string list -> bool
val conditions_bound_vars :
  ?constructor_op:Condition_pattern_certificate.t ->
  string list -> Maude_ir.eq_condition list -> string list
val rule_conditions_bound_vars :
  ?constructor_op:Condition_pattern_certificate.t ->
  string list -> Maude_ir.rule_condition list -> string list
val external_vars_of_term_after_conditions :
  ?constructor_op:Condition_pattern_certificate.t ->
  string list -> Maude_ir.term -> Maude_ir.eq_condition list -> string list
val external_vars_of_conditions :
  ?constructor_op:Condition_pattern_certificate.t ->
  string list -> Maude_ir.eq_condition list -> string list
val external_vars_of_rule_conditions :
  ?constructor_op:Condition_pattern_certificate.t ->
  string list -> Maude_ir.rule_condition list -> string list
val conditions_admissible_bound :
  ?constructor_op:Condition_pattern_certificate.t ->
  string list -> Maude_ir.eq_condition list -> string list option
val rule_conditions_admissible_bound :
  ?constructor_op:Condition_pattern_certificate.t ->
  string list -> Maude_ir.rule_condition list -> string list option
val helper_call_admissible_after_conditions :
  ?constructor_op:Condition_pattern_certificate.t ->
  string list -> Maude_ir.eq_condition list -> Maude_ir.term list -> bool
val normalize_binding_conditions :
  ?constructor_op:Condition_pattern_certificate.t ->
  Maude_ir.term list -> Maude_ir.eq_condition list -> Maude_ir.eq_condition list
val normalize_rule_conditions :
  ?constructor_op:Condition_pattern_certificate.t ->
  Maude_ir.term list ->
  Maude_ir.rule_condition list ->
  Maude_ir.rule_condition list
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
