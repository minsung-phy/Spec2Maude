module Request = Helper_request

type t = Helper_registry.t
type stage = Helper_registry.stage

let create = Helper_registry.create
let request = Helper_registry.request
let begin_stage = Helper_registry.begin_stage
let staged = Helper_registry.staged
let commit_stage = Helper_registry.commit_stage
let find = Helper_registry.find
let release = Helper_registry.release

let runtime_predicate_search_requests =
  Helper_registry.runtime_predicate_search_requests

let runtime_predicate_truth_search_requests =
  Helper_registry.runtime_predicate_truth_search_requests

let runtime_predicate_truth_decision_requests =
  Helper_registry.runtime_predicate_truth_decision_requests

let runtime_predicate_truth_worklist_requests =
  Helper_registry.runtime_predicate_truth_worklist_requests

let runtime_enabledness_requests =
  Helper_registry.runtime_enabledness_requests

let unmaterialized_diagnostics =
  Helper_registry.unmaterialized_diagnostics

let materialize_entry (entry : Helper_registry.entry) =
  match entry.request.kind with
  | Request.Membership_witness request ->
    Membership_witness_helper.materialize
      ~name:entry.name entry.request.origin request
  | Request.Iter_map map -> Helper_materialize_iter.materialize_iter_map entry map
  | Request.Iter_zip_map map ->
    Helper_materialize_iter.materialize_iter_zip_map entry map
  | Request.Iter_listn map -> Helper_materialize_iter.materialize_iter_listn entry map
  | Request.Iter_listn_source map ->
    Helper_materialize_iter.materialize_iter_listn_source entry map
  | Request.Iter_premise_opt_bool prem ->
    Helper_materialize_iter.materialize_iter_premise_opt_bool entry prem
  | Request.Iter_premise_list_bool prem ->
    Helper_materialize_iter.materialize_iter_premise_list_bool entry prem
  | Request.Iter_premise_list_rule prem ->
    Helper_materialize_iter.materialize_iter_premise_list_rule entry prem
  | Request.Iter_premise_zip_binding prem ->
    Helper_materialize_iter.materialize_iter_premise_zip_binding entry prem
  | Request.Iter_premise_exists_bool prem ->
    Helper_materialize_iter.materialize_iter_premise_exists_bool entry prem
  | Request.Iter_premise_exists_rule prem ->
    Helper_materialize_iter.materialize_iter_premise_exists_rule entry prem
  | Request.Iter_premise_zip_bool prem ->
    Helper_materialize_iter.materialize_iter_premise_zip_bool entry prem
  | Request.Iter_premise_zip_rule prem ->
    Helper_materialize_iter.materialize_iter_premise_zip_rule entry prem
  | Request.Iter_pattern_zip pattern ->
    Helper_materialize_iter.materialize_iter_pattern_zip entry pattern
  | Request.Fixed_inverse_concat2 inverse ->
    Helper_materialize_inverse.materialize_fixed_inverse_concat2 entry inverse
  | Request.Inverse_concatn_chunks inverse ->
    Helper_materialize_inverse.materialize_inverse_concatn_chunks entry inverse
  | Request.Optional_map_inverse inverse ->
    Helper_materialize_inverse.materialize_optional_map_inverse entry inverse
  | Request.Subtype_injection injection ->
    Helper_materialize_subtyping.materialize entry injection
  | Request.Runtime_predicate_search _
  | Request.Runtime_predicate_truth_search _
  | Request.Runtime_predicate_truth_decision _
  | Request.Runtime_predicate_truth_worklist _
  | Request.Runtime_enabledness _ -> []

let materialize_static registry =
  Helper_registry.entries registry |> List.concat_map materialize_entry
