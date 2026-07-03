val translate_premises :
  Context.t ->
  Expr_translate.env ->
  ?bound_conditions:Maude_ir.eq_condition list ->
  ?escape_source_ids:string list ->
  bound_terms:Maude_ir.term list ->
  Origin.t ->
  Il.Ast.prem list ->
  Premise_translate.result
