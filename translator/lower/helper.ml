include Helper_request

type entry = Helper_registry.entry =
  { name : string
  ; request : request
  }

type t = Helper_registry.t

let create = Helper_registry.create
let request = Helper_registry.request

let runtime_predicate_search_requests =
  Helper_registry.runtime_predicate_search_requests

let runtime_predicate_truth_search_requests =
  Helper_registry.runtime_predicate_truth_search_requests

let runtime_predicate_truth_decision_requests =
  Helper_registry.runtime_predicate_truth_decision_requests

let runtime_enabledness_requests =
  Helper_registry.runtime_enabledness_requests

let concatn_chunks_result_op =
  Helper_materialize_inverse.concatn_chunks_result_op

let concatn_chunks_inverse_op =
  Helper_materialize_inverse.concatn_chunks_inverse_op

let fixed_concat2_match_condition =
  Helper_materialize_inverse.fixed_concat2_match_condition

let unmaterialized_diagnostics =
  Helper_registry.unmaterialized_diagnostics

let materialize_entry entry =
  match entry.request.kind with
  | Iter_map map -> Helper_materialize_iter.materialize_iter_map entry map
  | Iter_zip_map map -> Helper_materialize_iter.materialize_iter_zip_map entry map
  | Iter_listn map -> Helper_materialize_iter.materialize_iter_listn entry map
  | Iter_listn_source map ->
    Helper_materialize_iter.materialize_iter_listn_source entry map
  | Iter_premise_opt_bool prem ->
    Helper_materialize_iter.materialize_iter_premise_opt_bool entry prem
  | Iter_premise_list_bool prem ->
    Helper_materialize_iter.materialize_iter_premise_list_bool entry prem
  | Iter_premise_exists_bool prem ->
    Helper_materialize_iter.materialize_iter_premise_exists_bool entry prem
  | Iter_premise_zip_bool prem ->
    Helper_materialize_iter.materialize_iter_premise_zip_bool entry prem
  | Iter_pattern_zip pattern ->
    Helper_materialize_iter.materialize_iter_pattern_zip entry pattern
  | Fixed_inverse_concat2 inverse ->
    Helper_materialize_inverse.materialize_fixed_inverse_concat2 entry inverse
  | Inverse_concatn_chunks inverse ->
    Helper_materialize_inverse.materialize_inverse_concatn_chunks entry inverse
  | Optional_map_inverse inverse ->
    Helper_materialize_inverse.materialize_optional_map_inverse entry inverse
  | Runtime_predicate_search _ | Runtime_predicate_truth_search _
  | Runtime_predicate_truth_decision _ | Runtime_enabledness _ -> []

let materialize registry =
  Helper_registry.entries registry |> List.concat_map materialize_entry
