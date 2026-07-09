type t =
  | Supported
  | Blocked of string list

val check_truth_request : Context.t -> Runtime_truth_search_helper.request -> t
val check : Context.t -> Runtime_truth_decision_helper.request -> t

val target_guided_seed_is_functional :
  Runtime_truth_decision_helper.request ->
  Runtime_witness_proof.target_chain ->
  bool
