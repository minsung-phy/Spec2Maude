open Maude_ir
open Helper_request

let term_key term =
  let rec loop = function
    | Var name -> "Var(" ^ name ^ ")"
    | Const name -> "Const(" ^ name ^ ")"
    | Qid qid -> "Qid(" ^ qid ^ ")"
    | App (name, args) ->
      "App(" ^ name ^ ";[" ^ String.concat ";" (List.map loop args) ^ "])"
  in
  loop term

let eq_condition_key = function
  | EqCond (lhs, rhs) -> "Eq(" ^ term_key lhs ^ "," ^ term_key rhs ^ ")"
  | MatchCond (lhs, rhs) -> "Match(" ^ term_key lhs ^ "," ^ term_key rhs ^ ")"
  | MembershipCond (subject, sort) ->
    "Member(" ^ term_key subject ^ "," ^ sort_name sort ^ ")"
  | BoolCond term -> "Bool(" ^ term_key term ^ ")"

let typ_key typ =
  Il.Print.string_of_typ typ

let source_shape_key (shape : iter_map_source_shape) =
  String.concat
    "\000"
    [ shape.iter_source
    ; shape.body_source
    ; shape.source_source
    ; shape.output_typ_source
    ; shape.source_typ_source
    ]

let zip_source_shape_key (shape : iter_zip_source_shape) =
  String.concat
    "\000"
    [ shape.generator_source_id; shape.source_source; shape.source_typ_source ]

let zip_map_source_shape_key (shape : iter_zip_map_source_shape) =
  String.concat
    "\000"
    [ shape.iter_source
    ; shape.body_source
    ; shape.output_typ_source
    ; String.concat "\001" (List.map zip_source_shape_key shape.sources)
    ]

let listn_mode_key = function
  | Repeat_count -> "repeat-count"
  | Indexed_from_zero -> "indexed-from-zero"

let listn_shape_key (shape : iter_listn_shape) =
  String.concat
    "\000"
    [ shape.iter_source
    ; shape.body_source
    ; shape.count_source
    ; shape.count_typ_source
    ; shape.output_typ_source
    ; listn_mode_key shape.mode
    ]

let listn_source_shape_key (shape : iter_listn_source_shape) =
  String.concat
    "\000"
    [ shape.iter_source
    ; shape.body_source
    ; shape.source_source
    ; shape.count_source
    ; shape.count_typ_source
    ; shape.output_typ_source
    ; shape.source_typ_source
    ]

let premise_opt_bool_shape_key (shape : iter_premise_opt_bool_shape) =
  String.concat
    "\000"
    [ shape.prem_source
    ; shape.body_source
    ; shape.source_source
    ; shape.source_typ_source
    ]

let premise_list_bool_shape_key (shape : iter_premise_list_bool_shape) =
  String.concat
    "\000"
    [ shape.prem_source
    ; shape.body_source
    ; shape.source_source
    ; shape.source_typ_source
    ; shape.iter_source
    ]

let premise_exists_bool_shape_key (shape : iter_premise_exists_bool_shape) =
  String.concat
    "\000"
    [ shape.prem_source
    ; shape.indexed_source
    ; shape.source_typ_source
    ; shape.predicate_source
    ]

let premise_zip_bool_shape_key (shape : iter_premise_zip_bool_shape) =
  String.concat
    "\000"
    [ shape.prem_source
    ; shape.body_source
    ; shape.iter_source
    ; String.concat "\001" (List.map zip_source_shape_key shape.sources)
    ]

let iter_pattern_zip_shape_key (shape : iter_pattern_zip_shape) =
  String.concat
    "\000"
    [ shape.pattern_source
    ; shape.body_source
    ; shape.iter_source
    ; String.concat "\001" (List.map zip_source_shape_key shape.sources)
    ]

let call_shape_key = function
  | Source_then_captures -> "source-then-captures"
  | Count_then_captures -> "count-then-captures"

let iter_map_source_item_shape_key = function
  | Source_flat_terminal -> "source-flat-terminal"
  | Source_nested_seq -> "source-nested-seq"

let iter_map_output_item_shape_key = function
  | Output_flat_terminal -> "output-flat-terminal"
  | Output_nested_seq -> "output-nested-seq"

let capture_key (capture : capture) =
  String.concat
    "\000"
    [ capture.source_id
    ; term_key capture.call_term
    ; capture.formal_var
    ; sort_name capture.sort
    ; typ_key capture.typ
    ]

let iter_map_key (map : iter_map) =
  String.concat
    "\000"
    [ source_shape_key map.source_shape
    ; call_shape_key map.call_shape
    ; map.generator_var
    ; map.helper_head_var
    ; map.source_tail_var
    ; map.body_result_var
    ; iter_map_source_item_shape_key map.source_item_shape
    ; iter_map_output_item_shape_key map.output_item_shape
    ; sort_name map.source_element_sort
    ; String.concat "\001" (List.map capture_key map.captures)
    ; term_key map.lowered_body
    ; String.concat "\001" (List.map eq_condition_key map.body_eq_conditions)
    ]

let iter_zip_source_key (source : iter_zip_source) =
  String.concat
    "\000"
    [ zip_source_shape_key source.source_shape
    ; iter_map_source_item_shape_key source.source_item_shape
    ; source.helper_head_var
    ; source.source_tail_var
    ; sort_name source.source_element_sort
    ]

let iter_zip_map_key (map : iter_zip_map) =
  String.concat
    "\000"
    [ zip_map_source_shape_key map.source_shape
    ; call_shape_key map.call_shape
    ; String.concat "\001" (List.map iter_zip_source_key map.sources)
    ; map.body_result_var
    ; iter_map_output_item_shape_key map.output_item_shape
    ; String.concat "\001" (List.map capture_key map.captures)
    ; term_key map.lowered_body
    ; String.concat "\001" (List.map eq_condition_key map.body_eq_conditions)
    ]

let iter_listn_key (map : iter_listn) =
  String.concat
    "\000"
    [ listn_shape_key map.source_shape
    ; call_shape_key map.call_shape
    ; map.count_var
    ; Option.value map.index_var ~default:""
    ; map.body_result_var
    ; iter_map_output_item_shape_key map.output_item_shape
    ; String.concat "\001" (List.map capture_key map.captures)
    ; term_key map.lowered_body
    ; String.concat "\001" (List.map eq_condition_key map.body_eq_conditions)
    ]

let iter_listn_source_key (map : iter_listn_source) =
  String.concat
    "\000"
    [ listn_source_shape_key map.source_shape
    ; map.count_var
    ; map.index_var
    ; map.generator_var
    ; map.helper_head_var
    ; map.source_tail_var
    ; map.body_result_var
    ; iter_map_source_item_shape_key map.source_item_shape
    ; iter_map_output_item_shape_key map.output_item_shape
    ; sort_name map.source_element_sort
    ; String.concat "\001" (List.map capture_key map.captures)
    ; term_key map.lowered_body
    ; String.concat "\001" (List.map eq_condition_key map.body_eq_conditions)
    ]

let iter_premise_opt_bool_key (prem : iter_premise_opt_bool) =
  String.concat
    "\000"
    [ premise_opt_bool_shape_key prem.source_shape
    ; prem.generator_var
    ; prem.helper_head_var
    ; prem.source_tail_var
    ; prem.body_result_var
    ; sort_name prem.source_element_sort
    ; String.concat "\001" (List.map capture_key prem.captures)
    ; term_key prem.lowered_body
    ; String.concat "\001" (List.map eq_condition_key prem.body_eq_conditions)
    ]

let iter_premise_list_bool_key (prem : iter_premise_list_bool) =
  String.concat
    "\000"
    [ premise_list_bool_shape_key prem.source_shape
    ; prem.generator_var
    ; prem.helper_head_var
    ; prem.source_tail_var
    ; sort_name prem.source_element_sort
    ; String.concat "\001" (List.map capture_key prem.captures)
    ; String.concat "\001" (List.map eq_condition_key prem.body_eq_conditions)
    ]

let iter_premise_exists_bool_key (prem : iter_premise_exists_bool) =
  String.concat
    "\000"
    [ premise_exists_bool_shape_key prem.source_shape
    ; prem.index_source_id
    ; prem.helper_head_var
    ; prem.source_tail_var
    ; sort_name prem.source_element_sort
    ; String.concat "\001" (List.map capture_key prem.captures)
    ; String.concat "\001" (List.map eq_condition_key prem.body_eq_conditions)
    ]

let iter_premise_zip_bool_key (prem : iter_premise_zip_bool) =
  String.concat
    "\000"
    [ premise_zip_bool_shape_key prem.source_shape
    ; String.concat "\001" (List.map iter_zip_source_key prem.sources)
    ; String.concat "\001" (List.map capture_key prem.captures)
    ; String.concat "\001" (List.map eq_condition_key prem.body_eq_conditions)
    ]

let iter_pattern_zip_source_key (source : iter_pattern_zip_source) =
  String.concat
    "\000"
    [ zip_source_shape_key source.source_shape
    ; iter_map_source_item_shape_key source.source_item_shape
    ; term_key source.source_head_term
    ; source.source_tail_var
    ]

let iter_pattern_zip_key (pattern : iter_pattern_zip) =
  String.concat
    "\000"
    [ iter_pattern_zip_shape_key pattern.source_shape
    ; term_key pattern.subject_item_term
    ; pattern.subject_tail_var
    ; String.concat "\001" (List.map iter_pattern_zip_source_key pattern.sources)
    ; String.concat "\001" (List.map eq_condition_key pattern.body_eq_conditions)
    ]

let optional_map_inverse_key (inverse : optional_map_inverse) =
  String.concat
    "\000"
    [ source_shape_key inverse.source_shape
    ; inverse.generator_var
    ; inverse.helper_head_var
    ; sort_name inverse.source_element_sort
    ; String.concat "\001" (List.map capture_key inverse.captures)
    ; term_key inverse.lowered_body
    ; String.concat "\001" (List.map eq_condition_key inverse.body_eq_conditions)
    ]

let inverse_concatn_chunks_key (inverse : inverse_concatn_chunks) =
  String.concat
    "\000"
    [ inverse.source
    ; inverse.target_source_id
    ; inverse.bytes_op
    ; inverse.inverse_op
    ; String.concat "\001" (List.map capture_key inverse.captures)
    ; String.concat "\001" (List.map term_key inverse.bytes_call_formals)
    ; String.concat "\001" (List.map term_key inverse.inverse_call_formals)
    ; inverse.target_head_var
    ; inverse.target_stream_var
    ; inverse.bytes_var
    ; inverse.bytes_head_var
    ; inverse.bytes_tail_var
    ; inverse.width_var
    ; inverse.count_tail_var
    ; inverse.chunk_var
    ]

let fixed_inverse_concat2_key (inverse : fixed_inverse_concat2) =
  fixed_inverse_concat2_source inverse

let origin_key origin =
  String.concat
    "\000"
    [ Origin.source_location origin
    ; Origin.path origin
    ; origin.Origin.ast_constructor
    ]

let kind_name = function
  | Iter_map _ -> "IterMap"
  | Iter_zip_map _ -> "IterZipMap"
  | Iter_listn _ -> "IterListN"
  | Iter_listn_source _ -> "IterListNSource"
  | Iter_premise_opt_bool _ -> "IterPremiseOptBool"
  | Iter_premise_list_bool _ -> "IterPremiseListBool"
  | Iter_premise_exists_bool _ -> "IterPremiseExistsBool"
  | Iter_premise_zip_bool _ -> "IterPremiseZipBool"
  | Iter_pattern_zip _ -> "IterPatternZip"
  | Fixed_inverse_concat2 _ -> "FixedInverseConcat2"
  | Inverse_concatn_chunks _ -> "InverseConcatnChunks"
  | Optional_map_inverse _ -> "OptionalMapInverse"
  | Runtime_predicate_search _ -> "RuntimePredicateSearch"
  | Runtime_predicate_truth_search _ -> "RuntimePredicateTruthSearch"
  | Runtime_predicate_truth_decision _ -> "RuntimePredicateTruthDecision"
  | Runtime_enabledness _ -> "RuntimeEnabledness"

let base_name request =
  "helper" ^ kind_name request.kind ^ Naming.helper_context_name request.origin

let key_of_kind = function
  | Iter_map map -> "iter-map:" ^ Digest.to_hex (Digest.string (iter_map_key map))
  | Iter_zip_map map ->
    "iter-zip-map:" ^ Digest.to_hex (Digest.string (iter_zip_map_key map))
  | Iter_listn map ->
    "iter-listn:" ^ Digest.to_hex (Digest.string (iter_listn_key map))
  | Iter_listn_source map ->
    "iter-listn-source:"
    ^ Digest.to_hex (Digest.string (iter_listn_source_key map))
  | Iter_premise_opt_bool prem ->
    "iter-premise-opt-bool:"
    ^ Digest.to_hex (Digest.string (iter_premise_opt_bool_key prem))
  | Iter_premise_list_bool prem ->
    "iter-premise-list-bool:"
    ^ Digest.to_hex (Digest.string (iter_premise_list_bool_key prem))
  | Iter_premise_exists_bool prem ->
    "iter-premise-exists-bool:"
    ^ Digest.to_hex (Digest.string (iter_premise_exists_bool_key prem))
  | Iter_premise_zip_bool prem ->
    "iter-premise-zip-bool:"
    ^ Digest.to_hex (Digest.string (iter_premise_zip_bool_key prem))
  | Iter_pattern_zip pattern ->
    "iter-pattern-zip:"
    ^ Digest.to_hex (Digest.string (iter_pattern_zip_key pattern))
  | Fixed_inverse_concat2 inverse ->
    "fixed-inverse-concat2:"
    ^ Digest.to_hex (Digest.string (fixed_inverse_concat2_key inverse))
  | Inverse_concatn_chunks inverse ->
    "inverse-concatn-chunks:"
    ^ Digest.to_hex (Digest.string (inverse_concatn_chunks_key inverse))
  | Optional_map_inverse inverse ->
    "optional-map-inverse:"
    ^ Digest.to_hex (Digest.string (optional_map_inverse_key inverse))
  | Runtime_predicate_search request ->
    "runtime-predicate-search:"
    ^ Digest.to_hex (Digest.string (Runtime_search_helper.key request))
  | Runtime_predicate_truth_search request ->
    "runtime-predicate-truth-search:"
    ^ Digest.to_hex (Digest.string (Runtime_truth_search_helper.key request))
  | Runtime_predicate_truth_decision request ->
    "runtime-predicate-truth-decision:"
    ^ Digest.to_hex (Digest.string (Runtime_truth_decision_helper.key request))
  | Runtime_enabledness request ->
    "runtime-enabledness:"
    ^ Digest.to_hex (Digest.string (Runtime_enabledness_helper.key request))

let has_materializer = function
  | Iter_map _ | Iter_zip_map _ | Iter_listn _ | Iter_listn_source _
  | Iter_premise_opt_bool _ | Iter_premise_list_bool _
  | Iter_premise_exists_bool _ | Iter_premise_zip_bool _ | Iter_pattern_zip _
  | Fixed_inverse_concat2 _ | Inverse_concatn_chunks _ | Optional_map_inverse _
  | Runtime_predicate_search _ | Runtime_predicate_truth_search _
  | Runtime_predicate_truth_decision _ | Runtime_enabledness _ -> true

let request_key request =
  match request.kind with
  | Runtime_predicate_search _ | Runtime_predicate_truth_search _
  | Runtime_predicate_truth_decision _ | Runtime_enabledness _ ->
    key_of_kind request.kind
  | _ -> origin_key request.origin ^ "\000" ^ key_of_kind request.kind

let key request =
  Digest.to_hex (Digest.string (request_key request))

let name ~used request =
  let base = base_name request in
  if not (used base) then
    base
  else
    let rec loop index =
      let candidate = base ^ string_of_int index in
      if used candidate then loop (index + 1) else candidate
    in
    loop 2
