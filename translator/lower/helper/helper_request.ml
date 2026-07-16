open Maude_ir

type iter_map_call_shape =
  | Source_then_captures
  | Count_then_captures

type iter_map_source_shape =
  { iter_source : string
  ; body_source : string
  ; source_source : string
  ; output_typ_source : string
  ; source_typ_source : string
  }

type iter_map_source_item_shape =
  | Source_flat_terminal
  | Source_nested_seq

type iter_map_output_item_shape =
  | Output_flat_terminal
  | Output_nested_seq

type capture =
  { source_id : string
  ; call_term : term
  ; formal_var : string
  ; sort : sort
  ; typ : Il.Ast.typ
  }

type iter_map =
  { source_shape : iter_map_source_shape
  ; call_shape : iter_map_call_shape
  ; generator_var : string
  ; helper_head_var : string
  ; source_tail_var : string
  ; body_result_var : string
  ; source_item_shape : iter_map_source_item_shape
  ; output_item_shape : iter_map_output_item_shape
  ; source_element_sort : sort
  ; captures : capture list
  ; lowered_body : term
  ; body_eq_conditions : eq_condition list
  }

type iter_zip_source_shape =
  { generator_source_id : string
  ; source_source : string
  ; source_typ_source : string
  }

type iter_zip_source =
  { source_shape : iter_zip_source_shape
  ; source_item_shape : iter_map_source_item_shape
  ; helper_head_var : string
  ; source_tail_var : string
  ; source_element_sort : sort
  }

type iter_zip_map_source_shape =
  { iter_source : string
  ; body_source : string
  ; output_typ_source : string
  ; sources : iter_zip_source_shape list
  }

type iter_zip_map =
  { source_shape : iter_zip_map_source_shape
  ; call_shape : iter_map_call_shape
  ; sources : iter_zip_source list
  ; body_result_var : string
  ; output_item_shape : iter_map_output_item_shape
  ; captures : capture list
  ; lowered_body : term
  ; body_eq_conditions : eq_condition list
  }

type iter_listn_mode =
  | Repeat_count
  | Indexed_from_zero

type iter_listn_shape =
  { iter_source : string
  ; body_source : string
  ; count_source : string
  ; count_typ_source : string
  ; output_typ_source : string
  ; mode : iter_listn_mode
  }

type iter_listn =
  { source_shape : iter_listn_shape
  ; call_shape : iter_map_call_shape
  ; count_var : string
  ; index_var : string option
  ; body_result_var : string
  ; output_item_shape : iter_map_output_item_shape
  ; captures : capture list
  ; lowered_body : term
  ; body_eq_conditions : eq_condition list
  }

type iter_listn_source_shape =
  { iter_source : string
  ; body_source : string
  ; source_source : string
  ; count_source : string
  ; count_typ_source : string
  ; output_typ_source : string
  ; source_typ_source : string
  }

type iter_listn_source =
  { source_shape : iter_listn_source_shape
  ; count_var : string
  ; index_var : string
  ; generator_var : string
  ; helper_head_var : string
  ; source_tail_var : string
  ; body_result_var : string
  ; source_item_shape : iter_map_source_item_shape
  ; output_item_shape : iter_map_output_item_shape
  ; source_element_sort : sort
  ; captures : capture list
  ; lowered_body : term
  ; body_eq_conditions : eq_condition list
  }

type iter_premise_opt_bool_shape =
  { prem_source : string
  ; body_source : string
  ; source_source : string
  ; source_typ_source : string
  }

type iter_premise_opt_bool =
  { source_shape : iter_premise_opt_bool_shape
  ; generator_var : string
  ; helper_head_var : string
  ; source_tail_var : string
  ; body_result_var : string
  ; source_element_sort : sort
  ; captures : capture list
  ; lowered_body : term
  ; body_eq_conditions : eq_condition list
  }

type iter_premise_list_bool_shape =
  { prem_source : string
  ; body_source : string
  ; source_source : string
  ; source_typ_source : string
  ; iter_source : string
  }

type iter_premise_list_bool =
  { source_shape : iter_premise_list_bool_shape
  ; generator_var : string
  ; helper_head_var : string
  ; source_tail_var : string
  ; source_element_sort : sort
  ; captures : capture list
  ; body_eq_conditions : eq_condition list
  }

type iter_premise_list_rule =
  { source_shape : iter_premise_list_bool_shape
  ; generator_var : string
  ; helper_head_var : string
  ; source_tail_var : string
  ; source_element_sort : sort
  ; captures : capture list
  ; body_conditions : rule_condition list
  }

type iter_premise_exists_bool_shape =
  { prem_source : string
  ; indexed_source : string
  ; source_typ_source : string
  ; predicate_source : string
  }

type iter_premise_exists_bool =
  { source_shape : iter_premise_exists_bool_shape
  ; index_source_id : string
  ; helper_head_var : string
  ; source_tail_var : string
  ; source_element_sort : sort
  ; captures : capture list
  ; body_eq_conditions : eq_condition list
  }

type iter_premise_exists_rule =
  { source_shape : iter_premise_exists_bool_shape
  ; index_source_id : string
  ; helper_head_var : string
  ; source_tail_var : string
  ; source_element_sort : sort
  ; captures : capture list
  ; body_conditions : rule_condition list
  }

type iter_premise_zip_bool_shape =
  { prem_source : string
  ; body_source : string
  ; iter_source : string
  ; sources : iter_zip_source_shape list
  }

type iter_premise_zip_bool =
  { source_shape : iter_premise_zip_bool_shape
  ; sources : iter_zip_source list
  ; captures : capture list
  ; body_eq_conditions : eq_condition list
  }

type iter_premise_zip_rule =
  { source_shape : iter_premise_zip_bool_shape
  ; sources : iter_zip_source list
  ; captures : capture list
  ; body_conditions : rule_condition list
  }

type iter_premise_binding_output =
  { source_item_shape : iter_map_source_item_shape
  ; helper_head_var : string
  ; source_tail_var : string
  ; source_element_sort : sort
  }

type iter_premise_zip_binding =
  { source_shape : iter_premise_zip_bool_shape
  ; sources : iter_zip_source list
  ; outputs : iter_premise_binding_output list
  ; captures : capture list
  ; body_eq_conditions : eq_condition list
  }

type iter_pattern_zip_shape =
  { pattern_source : string
  ; body_source : string
  ; iter_source : string
  ; sources : iter_zip_source_shape list
  }

type iter_pattern_zip_source =
  { source_shape : iter_zip_source_shape
  ; source_item_shape : iter_map_source_item_shape
  ; source_head_term : term
  ; source_tail_var : string
  }

type iter_pattern_zip =
  { source_shape : iter_pattern_zip_shape
  ; subject_item_term : term
  ; subject_tail_var : string
  ; sources : iter_pattern_zip_source list
  ; body_eq_conditions : eq_condition list
  }

type optional_map_inverse =
  { source_shape : iter_map_source_shape
  ; generator_var : string
  ; helper_head_var : string
  ; source_element_sort : sort
  ; captures : capture list
  ; lowered_body : term
  ; body_eq_conditions : eq_condition list
  }

type inverse_concatn_chunks =
  { source : string
  ; target_source_id : string
  ; bytes_op : string
  ; inverse_op : string
  ; captures : capture list
  ; bytes_call_formals : term list
  ; inverse_call_formals : term list
  ; target_head_var : string
  ; target_stream_var : string
  ; bytes_var : string
  ; bytes_head_var : string
  ; bytes_tail_var : string
  ; width_var : string
  ; count_tail_var : string
  ; chunk_var : string
  }

(* See helper_request.mli: callers must recheck the original forward equality
   after using this helper to bind the two source sequences. *)
type fixed_inverse_concat2 =
  { source : string
  }

type request_kind =
  | Membership_witness of Membership_witness_helper.request
  | Iter_map of iter_map
  | Iter_zip_map of iter_zip_map
  | Iter_listn of iter_listn
  | Iter_listn_source of iter_listn_source
  | Iter_premise_opt_bool of iter_premise_opt_bool
  | Iter_premise_list_bool of iter_premise_list_bool
  | Iter_premise_list_rule of iter_premise_list_rule
  | Iter_premise_zip_binding of iter_premise_zip_binding
  | Iter_premise_exists_bool of iter_premise_exists_bool
  | Iter_premise_exists_rule of iter_premise_exists_rule
  | Iter_premise_zip_bool of iter_premise_zip_bool
  | Iter_premise_zip_rule of iter_premise_zip_rule
  | Iter_pattern_zip of iter_pattern_zip
  | Fixed_inverse_concat2 of fixed_inverse_concat2
  | Inverse_concatn_chunks of inverse_concatn_chunks
  | Optional_map_inverse of optional_map_inverse
  | Subtype_injection of Subtype_injection.t
  | Runtime_predicate_search of Runtime_search_helper.request
  | Runtime_predicate_truth_search of Runtime_truth_search_helper.request
  | Runtime_predicate_truth_decision of Runtime_truth_decision_helper.request
  | Runtime_predicate_truth_worklist of Runtime_truth_worklist_helper.request
  | Runtime_enabledness of Runtime_enabledness_helper.request

type request =
  { kind : request_kind
  ; reason : string
  ; origin : Origin.t
  }

let fixed_inverse_concat2 ~source =
  { source }

let fixed_inverse_concat2_source inverse =
  inverse.source

let fixed_inverse_concat2_request ~origin ~source ~reason =
  { kind = Fixed_inverse_concat2 (fixed_inverse_concat2 ~source)
  ; reason
  ; origin
  }

let subtype_injection_request ~origin injection =
  { kind = Subtype_injection injection
  ; reason =
      "source-complete SubE injection from `"
      ^ Subtype_injection.source_category injection
      ^ "` to `" ^ Subtype_injection.target_category injection ^ "`"
  ; origin
  }
