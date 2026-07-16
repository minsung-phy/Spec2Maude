open Maude_ir
module Request = Helper_request

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

let rule_condition_key = function
  | EqCondition condition -> "EqCondition(" ^ eq_condition_key condition ^ ")"
  | RewriteCond (lhs, rhs) ->
    "Rewrite(" ^ term_key lhs ^ "," ^ term_key rhs ^ ")"

let typ_key typ =
  Il.Print.string_of_typ typ

let source_shape_key (shape : Request.iter_map_source_shape) =
  String.concat
    "\000"
    [ shape.iter_source
    ; shape.body_source
    ; shape.source_source
    ; shape.output_typ_source
    ; shape.source_typ_source
    ]

let zip_source_shape_key (shape : Request.iter_zip_source_shape) =
  String.concat
    "\000"
    [ shape.generator_source_id; shape.source_source; shape.source_typ_source ]

let zip_map_source_shape_key (shape : Request.iter_zip_map_source_shape) =
  String.concat
    "\000"
    [ shape.iter_source
    ; shape.body_source
    ; shape.output_typ_source
    ; String.concat "\001" (List.map zip_source_shape_key shape.sources)
    ]

let listn_mode_key = function
  | Request.Repeat_count -> "repeat-count"
  | Request.Indexed_from_zero -> "indexed-from-zero"

let listn_shape_key (shape : Request.iter_listn_shape) =
  String.concat
    "\000"
    [ shape.iter_source
    ; shape.body_source
    ; shape.count_source
    ; shape.count_typ_source
    ; shape.output_typ_source
    ; listn_mode_key shape.mode
    ]

let listn_source_shape_key (shape : Request.iter_listn_source_shape) =
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

let premise_opt_bool_shape_key (shape : Request.iter_premise_opt_bool_shape) =
  String.concat
    "\000"
    [ shape.prem_source
    ; shape.body_source
    ; shape.source_source
    ; shape.source_typ_source
    ]

let premise_list_bool_shape_key (shape : Request.iter_premise_list_bool_shape) =
  String.concat
    "\000"
    [ shape.prem_source
    ; shape.body_source
    ; shape.source_source
    ; shape.source_typ_source
    ; shape.iter_source
    ]

let premise_exists_bool_shape_key (shape : Request.iter_premise_exists_bool_shape) =
  String.concat
    "\000"
    [ shape.prem_source
    ; shape.indexed_source
    ; shape.source_typ_source
    ; shape.predicate_source
    ]

let premise_zip_bool_shape_key (shape : Request.iter_premise_zip_bool_shape) =
  String.concat
    "\000"
    [ shape.prem_source
    ; shape.body_source
    ; shape.iter_source
    ; String.concat "\001" (List.map zip_source_shape_key shape.sources)
    ]

let iter_pattern_zip_shape_key (shape : Request.iter_pattern_zip_shape) =
  String.concat
    "\000"
    [ shape.pattern_source
    ; shape.body_source
    ; shape.iter_source
    ; String.concat "\001" (List.map zip_source_shape_key shape.sources)
    ]

let call_shape_key = function
  | Request.Source_then_captures -> "source-then-captures"
  | Request.Count_then_captures -> "count-then-captures"

let iter_map_source_item_shape_key = function
  | Request.Source_flat_terminal -> "source-flat-terminal"
  | Request.Source_nested_seq -> "source-nested-seq"

let iter_map_output_item_shape_key = function
  | Request.Output_flat_terminal -> "output-flat-terminal"
  | Request.Output_nested_seq -> "output-nested-seq"

let capture_key (capture : Request.capture) =
  String.concat
    "\000"
    [ capture.Request.source_id
    ; term_key capture.Request.call_term
    ; capture.Request.formal_var
    ; sort_name capture.Request.sort
    ; typ_key capture.Request.typ
    ]

let iter_map_key (map : Request.iter_map) =
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

let iter_zip_source_key (source : Request.iter_zip_source) =
  String.concat
    "\000"
    [ zip_source_shape_key source.source_shape
    ; iter_map_source_item_shape_key source.source_item_shape
    ; source.helper_head_var
    ; source.source_tail_var
    ; sort_name source.source_element_sort
    ]

let iter_zip_map_key (map : Request.iter_zip_map) =
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

let iter_listn_key (map : Request.iter_listn) =
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

let iter_listn_source_key (map : Request.iter_listn_source) =
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

let iter_premise_opt_bool_key (prem : Request.iter_premise_opt_bool) =
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

let iter_premise_list_bool_key (prem : Request.iter_premise_list_bool) =
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

let iter_premise_list_rule_key (prem : Request.iter_premise_list_rule) =
  String.concat
    "\000"
    [ premise_list_bool_shape_key prem.source_shape
    ; prem.generator_var
    ; prem.helper_head_var
    ; prem.source_tail_var
    ; sort_name prem.source_element_sort
    ; String.concat "\001" (List.map capture_key prem.captures)
    ; String.concat "\001" (List.map rule_condition_key prem.body_conditions)
    ]

let iter_premise_binding_output_key (output : Request.iter_premise_binding_output) =
  String.concat
    "\001"
    [ iter_map_source_item_shape_key output.source_item_shape
    ; output.helper_head_var
    ; output.source_tail_var
    ; sort_name output.source_element_sort
    ]

let iter_premise_zip_binding_key (prem : Request.iter_premise_zip_binding) =
  String.concat
    "\000"
    [ premise_zip_bool_shape_key prem.source_shape
    ; String.concat "\001" (List.map iter_zip_source_key prem.sources)
    ; String.concat "\001" (List.map iter_premise_binding_output_key prem.outputs)
    ; String.concat "\001" (List.map capture_key prem.captures)
    ; String.concat "\001" (List.map eq_condition_key prem.body_eq_conditions)
    ]

let iter_premise_exists_bool_key (prem : Request.iter_premise_exists_bool) =
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

let iter_premise_exists_rule_key (prem : Request.iter_premise_exists_rule) =
  String.concat
    "\000"
    [ premise_exists_bool_shape_key prem.source_shape
    ; prem.index_source_id
    ; prem.helper_head_var
    ; prem.source_tail_var
    ; sort_name prem.source_element_sort
    ; String.concat "\001" (List.map capture_key prem.captures)
    ; String.concat "\001" (List.map rule_condition_key prem.body_conditions)
    ]

let iter_premise_zip_bool_key (prem : Request.iter_premise_zip_bool) =
  String.concat
    "\000"
    [ premise_zip_bool_shape_key prem.source_shape
    ; String.concat "\001" (List.map iter_zip_source_key prem.sources)
    ; String.concat "\001" (List.map capture_key prem.captures)
    ; String.concat "\001" (List.map eq_condition_key prem.body_eq_conditions)
    ]

let iter_premise_zip_rule_key (prem : Request.iter_premise_zip_rule) =
  String.concat
    "\000"
    [ premise_zip_bool_shape_key prem.source_shape
    ; String.concat "\001" (List.map iter_zip_source_key prem.sources)
    ; String.concat "\001" (List.map capture_key prem.captures)
    ; String.concat "\001" (List.map rule_condition_key prem.body_conditions)
    ]

let iter_pattern_zip_source_key (source : Request.iter_pattern_zip_source) =
  String.concat
    "\000"
    [ zip_source_shape_key source.source_shape
    ; iter_map_source_item_shape_key source.source_item_shape
    ; term_key source.source_head_term
    ; source.source_tail_var
    ]

let iter_pattern_zip_key (pattern : Request.iter_pattern_zip) =
  String.concat
    "\000"
    [ iter_pattern_zip_shape_key pattern.source_shape
    ; term_key pattern.subject_item_term
    ; pattern.subject_tail_var
    ; String.concat "\001" (List.map iter_pattern_zip_source_key pattern.sources)
    ; String.concat "\001" (List.map eq_condition_key pattern.body_eq_conditions)
    ]

let optional_map_inverse_key (inverse : Request.optional_map_inverse) =
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

let inverse_concatn_chunks_key (inverse : Request.inverse_concatn_chunks) =
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

let fixed_inverse_concat2_key (inverse : Request.fixed_inverse_concat2) =
  Request.fixed_inverse_concat2_source inverse

let origin_key origin =
  String.concat
    "\000"
    [ Origin.source_location origin
    ; Origin.path origin
    ; origin.Origin.ast_constructor
    ]

let kind_name = function
  | Request.Membership_witness _ -> "MembershipWitness"
  | Request.Iter_map _ -> "IterMap"
  | Request.Iter_zip_map _ -> "IterZipMap"
  | Request.Iter_listn _ -> "IterListN"
  | Request.Iter_listn_source _ -> "IterListNSource"
  | Request.Iter_premise_opt_bool _ -> "IterPremiseOptBool"
  | Request.Iter_premise_list_bool _ -> "IterPremiseListBool"
  | Request.Iter_premise_list_rule _ -> "IterPremiseListRule"
  | Request.Iter_premise_zip_binding _ -> "IterPremiseZipBinding"
  | Request.Iter_premise_exists_bool _ -> "IterPremiseExistsBool"
  | Request.Iter_premise_exists_rule _ -> "IterPremiseExistsRule"
  | Request.Iter_premise_zip_bool _ -> "IterPremiseZipBool"
  | Request.Iter_premise_zip_rule _ -> "IterPremiseZipRule"
  | Request.Iter_pattern_zip _ -> "IterPatternZip"
  | Request.Fixed_inverse_concat2 _ -> "FixedInverseConcat2"
  | Request.Inverse_concatn_chunks _ -> "InverseConcatnChunks"
  | Request.Optional_map_inverse _ -> "OptionalMapInverse"
  | Request.Subtype_injection _ -> "SubtypeInjection"
  | Request.Runtime_predicate_search _ -> "RuntimePredicateSearch"
  | Request.Runtime_predicate_truth_search _ -> "RuntimePredicateTruthSearch"
  | Request.Runtime_predicate_truth_decision _ -> "RuntimePredicateTruthDecision"
  | Request.Runtime_predicate_truth_worklist _ -> "RuntimePredicateTruthWorklist"
  | Request.Runtime_enabledness _ -> "RuntimeEnabledness"

let role_name = function
  | Request.Membership_witness _ -> "membership"
  | Request.Iter_map _ -> "iter-map"
  | Request.Iter_zip_map _ -> "iter-zip"
  | Request.Iter_listn _ -> "iter-count"
  | Request.Iter_listn_source _ -> "iter-index"
  | Request.Iter_premise_opt_bool _ -> "premise-opt"
  | Request.Iter_premise_list_bool _ -> "premise-all"
  | Request.Iter_premise_list_rule _ -> "premise-all-rule"
  | Request.Iter_premise_zip_binding _ -> "premise-zip-bind"
  | Request.Iter_premise_exists_bool _ -> "premise-exists"
  | Request.Iter_premise_exists_rule _ -> "premise-exists-rule"
  | Request.Iter_premise_zip_bool _ -> "premise-zip"
  | Request.Iter_premise_zip_rule _ -> "premise-zip-rule"
  | Request.Iter_pattern_zip _ -> "pattern-zip"
  | Request.Fixed_inverse_concat2 _ -> "inverse-pair"
  | Request.Inverse_concatn_chunks _ -> "inverse-chunks"
  | Request.Optional_map_inverse _ -> "inverse-opt"
  | Request.Subtype_injection _ -> "subtype-inject"
  | Request.Runtime_predicate_search _ -> "runtime-search"
  | Request.Runtime_predicate_truth_search _ -> "truth-search"
  | Request.Runtime_predicate_truth_decision _ -> "truth-decide"
  | Request.Runtime_predicate_truth_worklist _ -> "truth-worklist"
  | Request.Runtime_enabledness _ -> "enabledness"

let base_name request =
  Naming.helper_op
    ~role:(role_name request.Request.kind)
    ~owner:(Naming.helper_owner request.Request.origin)

let key_of_kind = function
  | Request.Membership_witness request ->
    "membership-witness:"
    ^ Digest.to_hex (Digest.string (Membership_witness_helper.key request))
  | Request.Iter_map map -> "iter-map:" ^ Digest.to_hex (Digest.string (iter_map_key map))
  | Request.Iter_zip_map map ->
    "iter-zip-map:" ^ Digest.to_hex (Digest.string (iter_zip_map_key map))
  | Request.Iter_listn map ->
    "iter-listn:" ^ Digest.to_hex (Digest.string (iter_listn_key map))
  | Request.Iter_listn_source map ->
    "iter-listn-source:"
    ^ Digest.to_hex (Digest.string (iter_listn_source_key map))
  | Request.Iter_premise_opt_bool prem ->
    "iter-premise-opt-bool:"
    ^ Digest.to_hex (Digest.string (iter_premise_opt_bool_key prem))
  | Request.Iter_premise_list_bool prem ->
    "iter-premise-list-bool:"
    ^ Digest.to_hex (Digest.string (iter_premise_list_bool_key prem))
  | Request.Iter_premise_list_rule prem ->
    "iter-premise-list-rule:"
    ^ Digest.to_hex (Digest.string (iter_premise_list_rule_key prem))
  | Request.Iter_premise_zip_binding prem ->
    "iter-premise-zip-binding:"
    ^ Digest.to_hex (Digest.string (iter_premise_zip_binding_key prem))
  | Request.Iter_premise_exists_bool prem ->
    "iter-premise-exists-bool:"
    ^ Digest.to_hex (Digest.string (iter_premise_exists_bool_key prem))
  | Request.Iter_premise_exists_rule prem ->
    "iter-premise-exists-rule:"
    ^ Digest.to_hex (Digest.string (iter_premise_exists_rule_key prem))
  | Request.Iter_premise_zip_bool prem ->
    "iter-premise-zip-bool:"
    ^ Digest.to_hex (Digest.string (iter_premise_zip_bool_key prem))
  | Request.Iter_premise_zip_rule prem ->
    "iter-premise-zip-rule:"
    ^ Digest.to_hex (Digest.string (iter_premise_zip_rule_key prem))
  | Request.Iter_pattern_zip pattern ->
    "iter-pattern-zip:"
    ^ Digest.to_hex (Digest.string (iter_pattern_zip_key pattern))
  | Request.Fixed_inverse_concat2 inverse ->
    "fixed-inverse-concat2:"
    ^ Digest.to_hex (Digest.string (fixed_inverse_concat2_key inverse))
  | Request.Inverse_concatn_chunks inverse ->
    "inverse-concatn-chunks:"
    ^ Digest.to_hex (Digest.string (inverse_concatn_chunks_key inverse))
  | Request.Optional_map_inverse inverse ->
    "optional-map-inverse:"
    ^ Digest.to_hex (Digest.string (optional_map_inverse_key inverse))
  | Request.Subtype_injection injection ->
    "subtype-injection:"
    ^ Digest.to_hex (Digest.string (Subtype_injection.key injection))
  | Request.Runtime_predicate_search request ->
    "runtime-predicate-search:"
    ^ Digest.to_hex (Digest.string (Runtime_search_helper.key request))
  | Request.Runtime_predicate_truth_search request ->
    "runtime-predicate-truth-search:"
    ^ Digest.to_hex (Digest.string (Runtime_truth_search_helper.key request))
  | Request.Runtime_predicate_truth_decision request ->
    "runtime-predicate-truth-decision:"
    ^ Digest.to_hex (Digest.string (Runtime_truth_decision_helper.key request))
  | Request.Runtime_predicate_truth_worklist request ->
    "runtime-predicate-truth-worklist:"
    ^ Digest.to_hex (Digest.string (Runtime_truth_worklist_helper.key request))
  | Request.Runtime_enabledness request ->
    "runtime-enabledness:"
    ^ Digest.to_hex (Digest.string (Runtime_enabledness_helper.key request))

let has_materializer = function
  | Request.Membership_witness _
  | Request.Iter_map _ | Request.Iter_zip_map _ | Request.Iter_listn _ | Request.Iter_listn_source _
  | Request.Iter_premise_opt_bool _ | Request.Iter_premise_list_bool _ | Request.Iter_premise_list_rule _
  | Request.Iter_premise_zip_binding _
  | Request.Iter_premise_exists_bool _ | Request.Iter_premise_zip_bool _ | Request.Iter_pattern_zip _
  | Request.Iter_premise_exists_rule _
  | Request.Iter_premise_zip_rule _
  | Request.Fixed_inverse_concat2 _ | Request.Inverse_concatn_chunks _ | Request.Optional_map_inverse _
  | Request.Subtype_injection _
  | Request.Runtime_predicate_search _ | Request.Runtime_predicate_truth_search _
  | Request.Runtime_predicate_truth_decision _ | Request.Runtime_enabledness _ -> true
  | Request.Runtime_predicate_truth_worklist _ -> true

let request_key request =
  match request.Request.kind with
  | Request.Subtype_injection _ | Request.Runtime_predicate_search _ | Request.Runtime_predicate_truth_search _
  | Request.Runtime_predicate_truth_decision _ | Request.Runtime_enabledness _ ->
    key_of_kind request.Request.kind
  | Request.Runtime_predicate_truth_worklist _ -> key_of_kind request.Request.kind
  | _ -> origin_key request.Request.origin ^ "\000" ^ key_of_kind request.Request.kind

let key request =
  Digest.to_hex (Digest.string (request_key request))

let name ~used request =
  let base = base_name request in
  if not (used base) then
    base
  else
    let rec loop index =
      let candidate = Naming.helper_ordinal base index in
      if used candidate then loop (index + 1) else candidate
    in
    loop 2
