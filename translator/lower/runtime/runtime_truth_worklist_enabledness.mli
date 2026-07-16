type decision =
  { positive_helper_name : string
  ; positive_request : Runtime_truth_worklist_helper.request
  ; total_helper_name : string
  ; total_request : Runtime_truth_worklist_helper.request
  }

val total_request_for_source_binders :
  current_terms:Maude_ir.term list ->
  predecessor_terms:Maude_ir.term list ->
  Runtime_truth_worklist_helper.request ->
  Runtime_truth_worklist_helper.request option

val positive_condition : decision -> Maude_ir.rule_condition
val false_condition : decision -> Maude_ir.rule_condition
val key : decision -> string
