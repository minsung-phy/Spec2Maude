val lower :
  Context.t ->
  Expr_translate.env ->
  allow_runtime_search:bool ->
  bound_vars:string list ->
  blocked_witness_source_ids:string list ->
  escape_source_ids:string list ->
  future_prems:Il.Ast.prem list ->
  Origin.t ->
  Il.Ast.prem ->
  Il.Ast.id ->
  Il.Ast.exp ->
  Relation_shape.t ->
  Premise_result.result
