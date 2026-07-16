type request =
  { helper_name : string
  ; origin : Origin.t
  ; identity : Runtime_truth_worklist_indexed.identity
  ; mode : Runtime_truth_worklist_indexed.mode
  ; candidates : Maude_ir.term
  ; captures : Runtime_truth_worklist_indexed.capture list
  ; support_head_var : string
  ; support_tail_var : string
  ; indexed_head_var : string
  ; indexed_tail_var : string
  ; domain_true : Maude_ir.rule_condition list
  ; domain_false : Maude_ir.rule_condition list list
  ; left_true : Maude_ir.rule_condition
  ; right_true : Maude_ir.rule_condition
  ; left_false : Maude_ir.rule_condition
  ; right_false : Maude_ir.rule_condition
  ; result_sort : Maude_ir.sort
  ; proved : Maude_ir.term
  ; refuted : Maude_ir.term
  }

val materialize : request -> Runtime_truth_worklist_indexed.result
