type item =
  { name : string
  ; origin : Origin.t
  ; request : Runtime_truth_worklist_helper.request
  }

type relation =
  { id : string
  ; sorts : Maude_ir.sort list
  ; rules : Runtime_truth_scc.rule list
  }

val generated :
  item -> Origin.t -> Maude_ir.statement_node -> Maude_ir.generated
val result_sort : item -> Maude_ir.sort
val terminal : Maude_ir.sort
val terminals : Maude_ir.sort
val prove_op : item -> string -> string
val refute_op : item -> string -> string
val all_op : item -> string -> string
val match_op : item -> int -> string
val rule_refute_op : item -> int -> string
val frozen_all : 'a list -> Maude_ir.attr list
val indexed_mode : item -> Runtime_truth_worklist_indexed.mode
val input_vars :
  Local_name.t -> Maude_ir.sort list -> Maude_ir.term list * Local_name.t
val public_vars : item -> Maude_ir.term list * Local_name.t
val public_lhs : item -> Maude_ir.term
val history_var : Local_name.t -> Maude_ir.term * Local_name.t
val goal : item -> relation -> Maude_ir.term list -> Maude_ir.term
val visited : item -> relation -> Maude_ir.term list -> Maude_ir.term -> Maude_ir.term
val push : item -> relation -> Maude_ir.term list -> Maude_ir.term -> Maude_ir.term
val relations : Runtime_truth_scc.t -> relation list
val diagnostic :
  Context.t ->
  item ->
  Origin.t ->
  string ->
  string ->
  string ->
  string option ->
  Diagnostics.t
val planner_diagnostic :
  Context.t -> item -> Runtime_truth_scc.blocker -> Diagnostics.t
val helper_surface : item -> Maude_ir.generated list
val surface_pattern_certificate :
  Context.t -> Maude_ir.generated list -> Condition_pattern_certificate.t
val helper_pattern_certificate :
  Context.t -> item -> Condition_pattern_certificate.t
val relation_surface : item -> relation -> Maude_ir.generated list
val rule_surface : item -> relation -> int -> Maude_ir.generated list
val find_relation : relation list -> string -> relation option
