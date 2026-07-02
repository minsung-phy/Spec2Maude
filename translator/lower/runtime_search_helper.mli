type target =
  { target_rel_id : string option
  ; target_source : string option
  ; target_premise : Il.Ast.prem
  }

type guide =
  { guide_rel_id : string
  ; guide_source : string option
  ; guide_input_terms : Maude_ir.term list
  ; guide_input_sorts : Maude_ir.sort list
  ; guide_witness_index : int
  }

type request =
  { rel_id : string
  ; witness_source_id : string
  ; targets : target list
  ; guides : guide list
  ; input_terms : Maude_ir.term list
  ; input_sorts : Maude_ir.sort list
  ; witness_index : int
  ; witness_term : Maude_ir.term
  ; witness_sort : Maude_ir.sort
  ; dependent_source_ids : string list
  ; closure : string list
  ; rules : Analysis.Function_graph.runtime_search_rule list
  ; witness_space : Runtime_witness_space.t
  }

type invocation =
  { search_op : string
  ; hit_op : string
  ; lhs : Maude_ir.term
  ; rhs : Maude_ir.term
  }

val key : request -> string
val reason : request -> string
val search_op : helper_name:string -> string
val hit_op : helper_name:string -> string
val invocation : helper_name:string -> request -> invocation
val rewrite_condition : helper_name:string -> request -> Maude_ir.rule_condition
