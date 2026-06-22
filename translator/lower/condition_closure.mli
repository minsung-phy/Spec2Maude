val term_vars : Maude_ir.term -> string list
val is_match_pattern : Maude_ir.term -> bool
val vars_subset : string list -> string list -> bool
val conditions_bound_vars :
  string list -> Maude_ir.eq_condition list -> string list
val external_vars_of_term_after_conditions :
  string list -> Maude_ir.term -> Maude_ir.eq_condition list -> string list
val external_vars_of_conditions :
  string list -> Maude_ir.eq_condition list -> string list
val conditions_admissible_bound :
  string list -> Maude_ir.eq_condition list -> string list option
val helper_call_admissible_after_conditions :
  string list -> Maude_ir.eq_condition list -> Maude_ir.term list -> bool
val normalize_binding_conditions :
  Maude_ir.term list -> Maude_ir.eq_condition list -> Maude_ir.eq_condition list
val normalize_rule_conditions :
  Maude_ir.term list ->
  Maude_ir.rule_condition list ->
  Maude_ir.rule_condition list
val ceq_admissibility_diagnostics :
  Context.t ->
  Origin.t ->
  Maude_ir.term ->
  Maude_ir.term ->
  Maude_ir.eq_condition list ->
  Diagnostics.t list
