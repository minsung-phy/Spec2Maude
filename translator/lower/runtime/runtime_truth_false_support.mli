type blocker

type t =
  | Supported
  | Blocked of blocker list

val blocker_reason : blocker -> string
val diagnostic : Context.t -> blocker -> Diagnostics.t

val check_truth_request : Context.t -> Runtime_truth_search_helper.request -> t
val check : Context.t -> Runtime_truth_decision_helper.request -> t
