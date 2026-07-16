type entry =
  { name : string
  ; request : Helper_request.request
  }

type t
type stage

val create : unit -> t
val request : t -> Helper_request.request -> string
val begin_stage : t -> stage
val request_staged : stage -> Helper_request.request -> string
val staged : stage -> t
val commit_stage : stage -> unit
val find : t -> Helper_request.request -> string option
val release : t -> Helper_request.request -> unit
val entries : t -> entry list
val runtime_predicate_search_requests :
  t -> (string * Origin.t * Runtime_search_helper.request) list
val runtime_predicate_truth_search_requests :
  t -> (string * Origin.t * Runtime_truth_search_helper.request) list
val runtime_predicate_truth_decision_requests :
  t -> (string * Origin.t * Runtime_truth_decision_helper.request) list
val runtime_predicate_truth_worklist_requests :
  t -> (string * Origin.t * Runtime_truth_worklist_helper.request) list
val runtime_enabledness_requests :
  t -> (string * Origin.t * Runtime_enabledness_helper.request) list
val unmaterialized_diagnostics : profile:string -> t -> Diagnostics.t list
