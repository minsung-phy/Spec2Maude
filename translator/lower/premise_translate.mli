type result = Premise_result.result =
  { eq_conditions : Maude_ir.eq_condition list
  ; rule_conditions : Maude_ir.rule_condition list
  ; has_else : bool
  ; let_bound_ids : string list list
  ; env_after : Expr_translate.env
  ; bound_vars_after : string list
  ; diagnostics : Diagnostics.t list
  }

val empty : result

val translate_premise :
  ?future_prems:Il.Ast.prem list ->
  Context.t ->
  Expr_translate.env ->
  bound_vars:string list ->
  Origin.t ->
  Il.Ast.prem ->
  result

val translate_premises :
  Context.t ->
  Expr_translate.env ->
  ?bound_conditions:Maude_ir.eq_condition list ->
  bound_terms:Maude_ir.term list ->
  Origin.t ->
  Il.Ast.prem list ->
  result
