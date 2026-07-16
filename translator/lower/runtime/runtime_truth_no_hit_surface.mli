type no_hit_call =
  { op : string
  ; ok : string
  ; lhs : Maude_ir.term
  ; rhs : Maude_ir.term
  }

type rule_refuter =
  { index : int
  ; op : string
  ; ok : string
  ; sort : Maude_ir.sort
  }

val generated :
  string -> Origin.t -> Maude_ir.statement_node -> Maude_ir.generated
val no_hit_op : string -> string
val no_hit_ok_op : string -> string
val all_rules_op : string -> string
val all_rules_ok_op : string -> string
val frozen_all : Maude_ir.sort list -> Maude_ir.attr list
val rule_refuter : string -> int -> rule_refuter
val spectec_terminals : Maude_ir.sort
val spectec_terminal : Maude_ir.sort
val no_hit_call :
  helper_name:string -> Runtime_truth_decision_helper.request -> no_hit_call
val all_rules_call : helper_name:string -> Maude_ir.term list -> Maude_ir.term
val all_rules_ok : string -> Maude_ir.term
val rule_refuter_call : rule_refuter -> Maude_ir.term list -> Maude_ir.term
val rule_refuter_ok : rule_refuter -> Maude_ir.term
val no_hit_surface :
  string -> Origin.t -> Runtime_truth_decision_helper.request -> Maude_ir.generated list
val all_rules_surface :
  string -> Origin.t -> Runtime_truth_decision_helper.request -> Maude_ir.generated list
val rule_refuter_surface :
  string ->
  Origin.t ->
  Runtime_truth_decision_helper.request ->
  Analysis.Function_graph.runtime_search_rule list ->
  Maude_ir.generated list
val indexed_false_sort : string -> int -> int -> Maude_ir.sort
val indexed_false_op : string -> int -> int -> string
val indexed_false_ok_op : string -> int -> int -> string
val indexed_head_no_match_sort : string -> int -> Maude_ir.sort
val indexed_head_no_match_op : string -> int -> string
val indexed_head_no_match_ok_op : string -> int -> string
val indexed_false_call : string -> Maude_ir.term -> Maude_ir.term list -> Maude_ir.term
val indexed_head_no_match_call : string -> Maude_ir.term -> Maude_ir.term -> Maude_ir.term
