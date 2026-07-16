type binding_diagnostic =
  { constructor : string
  ; reason : string
  ; suggestion : string
  ; blocked_witness_source_ids : string list
  }

type local_existential_plan =
  | Search_ready of
      { rel_id : string
      ; witness_source_id : string
      ; targets : Runtime_search_helper.target list
      ; dependent_source_ids : string list
      ; closure : string list
      ; rules : Analysis.Function_graph.runtime_search_rule list
      ; witness_space : Runtime_witness_space.t
      }
  | Search_blocked of
      { rel_id : string
      ; witness_source_id : string
      ; targets : Runtime_search_helper.target list
      ; dependent_source_ids : string list
      ; closure : string list
      ; rules : Analysis.Function_graph.runtime_search_rule list
      ; blockers : Analysis.Function_graph.runtime_search_blocker list
      ; witness_blockers : Runtime_witness_space.blocker list
      }

type truth_plan =
  | Truth_not_needed
  | Truth_ready of
      { rel_id : string
      ; closure : string list
      ; rules : Analysis.Function_graph.runtime_search_rule list
      }
  | Truth_blocked of
      { rel_id : string
      ; closure : string list
      ; rules : Analysis.Function_graph.runtime_search_rule list
      ; blockers : Analysis.Function_graph.runtime_search_blocker list
      }

val local_existential_plan :
  Context.t ->
  string ->
  missing_sources:string list ->
  escape_source_ids:string list ->
  future_prems:Il.Ast.prem list ->
  local_existential_plan option

val helper_request :
  input_terms:Maude_ir.term list ->
  input_sorts:Maude_ir.sort list ->
  guides:Runtime_search_helper.guide list ->
  witness_index:int ->
  witness_term:Maude_ir.term ->
  witness_sort:Maude_ir.sort ->
  local_existential_plan ->
  Runtime_search_helper.request option

val binding_diagnostic :
  Context.t ->
  string ->
  missing_sources:string list ->
  escape_source_ids:string list ->
  future_prems:Il.Ast.prem list ->
  binding_diagnostic option

val truth_plan : Context.t -> string -> truth_plan

val truth_helper_request :
  input_terms:Maude_ir.term list ->
  input_sorts:Maude_ir.sort list ->
  truth_plan ->
  Runtime_truth_search_helper.request option

val truth_worklist_request :
  Context.t ->
  rel_id:string ->
  input_terms:Maude_ir.term list ->
  input_sorts:Maude_ir.sort list ->
  Runtime_truth_worklist_helper.request option

val truth_worklist_blockers : Context.t -> string -> string list

val truth_diagnostic : Context.t -> string -> binding_diagnostic option
