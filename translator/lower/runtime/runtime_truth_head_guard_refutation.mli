type result =
  | Complete of Maude_ir.eq_condition list list
  | Blocked of string

val complement :
  ?pattern_certificate:Condition_pattern_certificate.t ->
  bound_terms:Maude_ir.term list ->
  Maude_ir.eq_condition list ->
  result
