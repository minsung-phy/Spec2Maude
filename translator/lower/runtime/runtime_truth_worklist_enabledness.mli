type decision =
  { positive_helper_name : string
  ; positive_request : Runtime_truth_worklist_helper.request
  ; total_helper_name : string
  ; total_request : Runtime_truth_worklist_helper.request
  }

type total_request_result =
  | Ready of Runtime_truth_worklist_helper.request
  | Head_mismatch
  | Incomplete_decision of string list

val total_request_for_source_binders :
  current_terms:Maude_ir.term list ->
  predecessor_terms:Maude_ir.term list ->
  Runtime_truth_worklist_helper.request ->
  total_request_result

val positive_condition : decision -> Maude_ir.rule_condition
val false_condition : decision -> Maude_ir.rule_condition
val key : decision -> string
