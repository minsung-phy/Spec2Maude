val term_matches_general : Maude_ir.term -> Maude_ir.term -> bool
val terms_match_general : Maude_ir.term list -> Maude_ir.term list -> bool
val term_vars : Maude_ir.term -> string list

val substitute_term :
  (string * Maude_ir.term) list -> Maude_ir.term -> Maude_ir.term

val substitute_condition :
  (string * Maude_ir.term) list ->
  Maude_ir.eq_condition ->
  Maude_ir.eq_condition

val collect_head_subst :
  Maude_ir.term list ->
  Maude_ir.term list ->
  (string * Maude_ir.term) list option

val specialize_terms :
  Maude_ir.term list ->
  Maude_ir.term list ->
  Maude_ir.term list ->
  Maude_ir.term list option
