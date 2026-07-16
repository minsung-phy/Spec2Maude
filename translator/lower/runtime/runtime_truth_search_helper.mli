type recursion =
  | Acyclic
  | Finite_transitive of Runtime_witness_proof.closed_world_domain
  | Target_guided_self of Runtime_witness_proof.target_chain
  | Recursive of string list

type request =
  { rel_id : string
  ; input_terms : Maude_ir.term list
  ; input_sorts : Maude_ir.sort list
  ; recursion : recursion
  ; closure : string list
  ; rules : Analysis.Function_graph.runtime_search_rule list
  }

type invocation =
  { search_op : string
  ; ok_op : string
  ; lhs : Maude_ir.term
  ; rhs : Maude_ir.term
  }

val key : request -> string
val reason : request -> string
val search_op : helper_name:string -> string
val ok_op : helper_name:string -> string
val invocation : helper_name:string -> request -> invocation
val rewrite_condition : helper_name:string -> request -> Maude_ir.rule_condition
val surface :
  helper_name:string ->
  origin:Origin.t ->
  request ->
  Maude_ir.generated list
