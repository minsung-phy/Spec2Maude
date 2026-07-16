type decision =
  { positive_helper_name : string
  ; positive_request : Runtime_truth_worklist_helper.request
  ; total_helper_name : string
  ; total_request : Runtime_truth_worklist_helper.request
  }

let total_request_for_source_binders
    ~current_terms ~predecessor_terms
    (request : Runtime_truth_worklist_helper.request) =
  match
    Head_specialization.specialize_terms
      current_terms predecessor_terms request.input_terms
  with
  | None -> None
  | Some _ when Runtime_truth_scc.decision_complete request.plan ->
    Some { request with Runtime_truth_worklist_helper.mode = Decide }
  | Some _ -> None

let positive_condition decision =
  Runtime_truth_worklist_helper.true_condition
    ~helper_name:decision.positive_helper_name decision.positive_request

let false_condition decision =
  Runtime_truth_worklist_helper.false_condition
    ~helper_name:decision.total_helper_name decision.total_request

let key decision =
  String.concat "\000"
    [ decision.positive_helper_name
    ; Runtime_truth_worklist_helper.key decision.positive_request
    ; decision.total_helper_name
    ; Runtime_truth_worklist_helper.key decision.total_request
    ]
