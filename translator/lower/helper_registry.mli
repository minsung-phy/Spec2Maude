type entry =
  { name : string
  ; request : Helper_request.request
  }

type t

val create : unit -> t
val request : t -> Helper_request.request -> string
val entries : t -> entry list
val runtime_predicate_search_requests :
  t -> (string * Origin.t * Runtime_search_helper.request) list
val runtime_predicate_truth_search_requests :
  t -> (string * Origin.t * Runtime_truth_search_helper.request) list
val runtime_predicate_truth_decision_requests :
  t -> (string * Origin.t * Runtime_truth_decision_helper.request) list
val runtime_enabledness_requests :
  t -> (string * Origin.t * Runtime_enabledness_helper.request) list
val unmaterialized_diagnostics : profile:string -> t -> Diagnostics.t list
