val predecessor_matches_current :
  Maude_ir.term list -> Maude_ir.term list -> bool

val predecessor_refines_constructor :
  Maude_ir.term list -> Maude_ir.term list -> bool

val sequential_complement_conditions :
  Maude_ir.term list ->
  Maude_ir.eq_condition list ->
  Maude_ir.rule_condition list option

val direct_complement_conditions :
  Maude_ir.term list ->
  Maude_ir.term list ->
  Maude_ir.eq_condition list ->
  Maude_ir.rule_condition list option
