type target =
  { target_rel_id : string option
  ; target_source : string option
  ; target_premise : Il.Ast.prem
  }

type blocker =
  { relation_id : string
  ; rule_id : string option
  ; origin : Origin.t option
  ; constructor : string
  ; reason : string
  ; suggestion : string
  ; source_echo : string option
  }

type t

val proof : t -> Runtime_witness_proof.t
val proof_for_closure :
  closure:string list ->
  rules:Analysis.Function_graph.runtime_search_rule list ->
  (Runtime_witness_proof.t, blocker list) result

val proof_for_truth_relation :
  rel_id:string ->
  closure:string list ->
  rules:Analysis.Function_graph.runtime_search_rule list ->
  (Runtime_witness_proof.t, blocker list) result

val prove :
  rel_id:string ->
  witness_source_id:string ->
  targets:target list ->
  closure:string list ->
  rules:Analysis.Function_graph.runtime_search_rule list ->
  (t, blocker list) result

val key : t -> string
val closure : t -> string list
val rules : t -> Analysis.Function_graph.runtime_search_rule list
