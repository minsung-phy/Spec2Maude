type result = Premise_result.result =
  { eq_conditions : Maude_ir.eq_condition list
  ; rule_conditions : Maude_ir.rule_condition list
  ; has_else : bool
  ; let_bound_ids : string list list
  ; env_after : Expr_translate.env
  ; bound_vars_after : string list
  ; blocked_witness_source_ids : string list
  ; runtime_search_requests : Runtime_search_helper.request list
  ; runtime_truth_search_requests : Runtime_truth_search_helper.request list
  ; diagnostics : Diagnostics.t list
  }

val empty : result

val translate_premise :
  ?allow_runtime_search:bool ->
  ?future_prems:Il.Ast.prem list ->
  ?escape_source_ids:string list ->
  ?blocked_witness_source_ids:string list ->
  Context.t ->
  Expr_translate.env ->
  bound_vars:string list ->
  Origin.t ->
  Il.Ast.prem ->
  result

val translate_premises :
  ?allow_runtime_search:bool ->
  Context.t ->
  Expr_translate.env ->
  ?bound_conditions:Maude_ir.eq_condition list ->
  ?escape_source_ids:string list ->
  bound_terms:Maude_ir.term list ->
  Origin.t ->
  Il.Ast.prem list ->
  result
