include module type of Helper_request

type t

val create : unit -> t
val request : t -> request -> string
val runtime_predicate_search_requests :
  t -> (string * Origin.t * Runtime_search_helper.request) list
val runtime_predicate_truth_search_requests :
  t -> (string * Origin.t * Runtime_truth_search_helper.request) list
val runtime_predicate_truth_decision_requests :
  t -> (string * Origin.t * Runtime_truth_decision_helper.request) list
val runtime_enabledness_requests :
  t -> (string * Origin.t * Runtime_enabledness_helper.request) list
val concatn_chunks_result_op : string -> string
val concatn_chunks_inverse_op : string -> string
val fixed_concat2_match_condition :
  string ->
  type_witness:Maude_ir.term ->
  known:Maude_ir.term ->
  left:Maude_ir.term ->
  right:Maude_ir.term ->
  Maude_ir.eq_condition
val unmaterialized_diagnostics : profile:string -> t -> Diagnostics.t list
val materialize : t -> Maude_ir.generated list
