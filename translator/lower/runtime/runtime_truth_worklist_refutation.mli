open Runtime_truth_worklist_core

module Refutation : sig
  val lower_rule :
    Context.t ->
    item ->
    relation list ->
    relation ->
    int ->
    Runtime_truth_scc.rule ->
    Maude_ir.generated list * Diagnostics.t list

  val solver :
    item ->
    relation ->
    (int * Runtime_truth_scc.rule) list ->
    Maude_ir.generated list
end
