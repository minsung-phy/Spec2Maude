val dedup_terms : Maude_ir.term list -> Maude_ir.term list

val terminal_sequence : Maude_ir.term list -> Maude_ir.term

val query_candidates :
  Runtime_witness_domain.t ->
  Maude_ir.term list ->
  Maude_ir.term list

val split_exps :
  int ->
  Il.Ast.exp list ->
  (Il.Ast.exp * Il.Ast.exp) option

val rule_head_candidates :
  Context.t ->
  parent:Origin.t ->
  input_count:int ->
  Runtime_witness_domain.t ->
  Analysis.Function_graph.runtime_search_rule list ->
  Maude_ir.term list * Diagnostics.t list
