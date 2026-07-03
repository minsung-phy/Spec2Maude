val try_skip_rulepr_validation_witness :
  Context.t ->
  Expr_translate.env ->
  bound_vars:string list ->
  future_prems:Il.Ast.prem list ->
  escape_source_ids:string list ->
  Origin.t ->
  Il.Ast.prem ->
  Il.Ast.id ->
  Il.Ast.mixop ->
  Premise_result.result option

val try_skip_iterpr_validation_witness :
  Context.t ->
  Expr_translate.env ->
  bound_vars:string list ->
  future_prems:Il.Ast.prem list ->
  escape_source_ids:string list ->
  Origin.t ->
  Il.Ast.prem ->
  Il.Ast.prem ->
  Il.Ast.iter ->
  (Il.Ast.id * Il.Ast.exp) list ->
  Premise_result.result option
