val translate_premise :
  ?allow_runtime_search:bool ->
  ?discharge_static_validation:bool ->
  ?future_prems:Il.Ast.prem list ->
  ?escape_source_ids:string list ->
  ?blocked_witness_source_ids:string list ->
  ?factor_head_domains:bool ->
  ?lhs_bound_vars:string list ->
  Context.t ->
  Expr_env.t ->
  bound_vars:string list ->
  Origin.t ->
  Il.Ast.prem ->
  Premise_result.outcome

val translate_premise_named :
  Local_name.t ->
  ?allow_runtime_search:bool ->
  ?discharge_static_validation:bool ->
  ?future_prems:Il.Ast.prem list ->
  ?escape_source_ids:string list ->
  ?blocked_witness_source_ids:string list ->
  ?factor_head_domains:bool ->
  ?lhs_bound_vars:string list ->
  Context.t ->
  Expr_env.t ->
  bound_vars:string list ->
  Origin.t ->
  Il.Ast.prem ->
  Premise_result.outcome * Local_name.t

val translate_premises :
  ?allow_runtime_search:bool ->
  ?discharge_static_validation:bool ->
  ?factor_head_domains:bool ->
  ?condition_declarations:Maude_ir.generated list ->
  Context.t ->
  Expr_env.t ->
  ?bound_conditions:Maude_ir.eq_condition list ->
  ?escape_source_ids:string list ->
  bound_terms:Maude_ir.term list ->
  Origin.t ->
  Il.Ast.prem list ->
  Premise_result.outcome

val translate_premises_named :
  Local_name.t ->
  ?allow_runtime_search:bool ->
  ?discharge_static_validation:bool ->
  ?factor_head_domains:bool ->
  ?condition_declarations:Maude_ir.generated list ->
  Context.t ->
  Expr_env.t ->
  ?bound_conditions:Maude_ir.eq_condition list ->
  ?escape_source_ids:string list ->
  bound_terms:Maude_ir.term list ->
  Origin.t ->
  Il.Ast.prem list ->
  Premise_result.outcome * Local_name.t
