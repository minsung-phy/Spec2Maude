val discharge :
  Context.t ->
  Expr_env.t ->
  lhs_terms:Maude_ir.term list ->
  Maude_ir.rule_condition list ->
  Maude_ir.rule_condition list

val discharge_eq :
  Context.t ->
  Expr_env.t ->
  lhs_terms:Maude_ir.term list ->
  Maude_ir.eq_condition list ->
  Maude_ir.eq_condition list
