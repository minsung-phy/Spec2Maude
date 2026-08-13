val translate_premises_named :
  Local_name.t ->
  Context.t ->
  Expr_env.t ->
  ?bound_conditions:Maude_ir.eq_condition list ->
  ?head_facts:Maude_ir.eq_condition list ->
  ?escape_source_ids:string list ->
  bound_terms:Maude_ir.term list ->
  Origin.t ->
  Il.Ast.prem list ->
  Premise_result.outcome * Local_name.t
