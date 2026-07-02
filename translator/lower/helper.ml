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

type inverse_pair_split =
  { source : string
  ; left_source_id : string
  ; right_source_id : string
  ; pair_source : string
  ; left_head_var : string
  ; right_head_var : string
  ; left_stream_var : string
  ; right_stream_var : string
  ; source_tail_var : string
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

type optional_map_inverse =
  { source_shape : iter_map_source_shape
  ; generator_var : string
  ; helper_head_var : string
  ; source_element_sort : sort
  ; captures : capture list
  ; lowered_body : term
  ; body_eq_conditions : eq_condition list
  }

type request_kind =
  | Iter_map of iter_map
  | Iter_zip_map of iter_zip_map
  | Iter_listn of iter_listn
  | Iter_listn_source of iter_listn_source
  | Iter_premise_opt_bool of iter_premise_opt_bool
  | Iter_premise_list_bool of iter_premise_list_bool
  | Iter_premise_exists_bool of iter_premise_exists_bool
  | Iter_premise_zip_bool of iter_premise_zip_bool
  | Iter_pattern_zip of iter_pattern_zip
  | Inverse_pair_split of inverse_pair_split
  | Inverse_concatn_chunks of inverse_concatn_chunks
  | Optional_map_inverse of optional_map_inverse
  | Optional_branch of { shape : string }
  | List1_guard of { shape : string }
  | Listn_indexed of { shape : string }
  | Membership_binding of { shape : string }
  | Sequence_splice of { shape : string }
  | Enabledness_complement of { shape : string }
  | Rewrite_dependent of { shape : string }
  | Runtime_predicate_search of Runtime_search_helper.request
  | Runtime_predicate_truth_search of Runtime_truth_search_helper.request
  | Runtime_predicate_truth_decision of Runtime_truth_decision_helper.request
  | Runtime_enabledness of Runtime_enabledness_helper.request

type request =
  { kind : request_kind
  ; reason : string
  ; origin : Origin.t
  }

type entry =
  { key : string
  ; name : string
  ; request : request
  }

type t = { mutable entries : entry list }

let create () = { entries = [] }

let term_key term =
  let rec loop = function
    | Var name -> "Var(" ^ name ^ ")"
    | Const name -> "Const(" ^ name ^ ")"
    | Qid qid -> "Qid(" ^ qid ^ ")"
    | App (name, args) ->
      "App(" ^ name ^ ";[" ^ String.concat ";" (List.map loop args) ^ "])"
  in
  loop term

let term_vars term =
  let rec loop acc = function
    | Var name -> name :: acc
    | Const _ | Qid _ -> acc
    | App (_, args) -> List.fold_left loop acc args
  in
  loop [] term |> List.sort_uniq String.compare

let add_unique vars acc =
  List.fold_left
    (fun acc var -> if List.exists (( = ) var) acc then acc else var :: acc)
    acc vars

let vars_within bound vars =
  vars |> List.for_all (fun var -> List.exists (( = ) var) bound)

let condition_required_vars bound = function
  | EqCond (lhs, rhs) ->
    term_vars lhs @ term_vars rhs
    |> List.sort_uniq String.compare
    |> List.filter (fun var -> not (List.exists (( = ) var) bound))
  | MatchCond (_pattern, subject) ->
    term_vars subject
    |> List.filter (fun var -> not (List.exists (( = ) var) bound))
  | MembershipCond (subject, _)
  | BoolCond subject ->
    term_vars subject
    |> List.filter (fun var -> not (List.exists (( = ) var) bound))

let condition_bound_vars = function
  | MatchCond (pattern, _subject) -> term_vars pattern
  | EqCond _ | MembershipCond _ | BoolCond _ -> []

let scheduled_condition bound = function
  | MatchCond (pattern, subject)
    when vars_within bound (term_vars pattern) ->
    EqCond (pattern, subject)
  | condition -> condition

let schedule_eq_conditions initial_bound conditions =
  let rec loop bound scheduled remaining =
    match remaining with
    | [] -> Some (List.rev scheduled)
    | _ ->
      (match
         remaining
         |> List.find_opt (fun condition ->
           vars_within bound (condition_required_vars bound condition))
       with
      | None -> None
      | Some chosen ->
        let remaining =
          remaining |> List.filter (fun condition -> condition != chosen)
        in
        let scheduled_chosen = scheduled_condition bound chosen in
        let bound = add_unique (condition_bound_vars chosen) bound in
        loop bound (scheduled_chosen :: scheduled) remaining)
  in
  loop initial_bound [] conditions

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

let inverse_pair_split_key (split : inverse_pair_split) =
  String.concat
    "\000"
    [ split.source
    ; split.left_source_id
    ; split.right_source_id
    ; split.pair_source
    ; split.left_head_var
    ; split.right_head_var
    ; split.left_stream_var
    ; split.right_stream_var
    ; split.source_tail_var
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
  | Inverse_pair_split _ -> "InversePairSplit"
  | Inverse_concatn_chunks _ -> "InverseConcatnChunks"
  | Optional_map_inverse _ -> "OptionalMapInverse"
  | Optional_branch _ -> "OptionalBranch"
  | List1_guard _ -> "List1Guard"
  | Listn_indexed _ -> "ListNIndexed"
  | Membership_binding _ -> "MembershipBinding"
  | Sequence_splice _ -> "SequenceSplice"
  | Enabledness_complement _ -> "EnablednessComplement"
  | Rewrite_dependent _ -> "RewriteDependent"
  | Runtime_predicate_search _ -> "RuntimePredicateSearch"
  | Runtime_predicate_truth_search _ -> "RuntimePredicateTruthSearch"
  | Runtime_predicate_truth_decision _ -> "RuntimePredicateTruthDecision"
  | Runtime_enabledness _ -> "RuntimeEnabledness"

let helper_base_name request =
  "helper" ^ kind_name request.kind ^ Naming.helper_context_name request.origin

let unique_helper_name registry base =
  let used name = registry.entries |> List.exists (fun entry -> entry.name = name) in
  if not (used base) then
    base
  else
    let rec loop index =
      let candidate = base ^ string_of_int index in
      if used candidate then loop (index + 1) else candidate
    in
    loop 2

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
  | Inverse_pair_split split ->
    "inverse-pair-split:" ^ Digest.to_hex (Digest.string (inverse_pair_split_key split))
  | Inverse_concatn_chunks inverse ->
    "inverse-concatn-chunks:"
    ^ Digest.to_hex (Digest.string (inverse_concatn_chunks_key inverse))
  | Optional_map_inverse inverse ->
    "optional-map-inverse:"
    ^ Digest.to_hex (Digest.string (optional_map_inverse_key inverse))
  | Optional_branch { shape } -> "optional-branch:" ^ shape
  | List1_guard { shape } -> "list1-guard:" ^ shape
  | Listn_indexed { shape } -> "listn-indexed:" ^ shape
  | Membership_binding { shape } -> "membership-binding:" ^ shape
  | Sequence_splice { shape } -> "sequence-splice:" ^ shape
  | Enabledness_complement { shape } -> "enabledness-complement:" ^ shape
  | Rewrite_dependent { shape } -> "rewrite-dependent:" ^ shape
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

let kind_has_materializer = function
  | Iter_map _ | Iter_zip_map _ | Iter_listn _ | Iter_listn_source _
  | Iter_premise_opt_bool _ | Iter_premise_list_bool _
  | Iter_premise_exists_bool _ | Iter_premise_zip_bool _ | Iter_pattern_zip _
  | Inverse_pair_split _ | Inverse_concatn_chunks _ | Optional_map_inverse _
  | Runtime_predicate_search _ | Runtime_predicate_truth_search _
  | Runtime_predicate_truth_decision _ | Runtime_enabledness _ -> true
  | Optional_branch _ | List1_guard _ | Listn_indexed _ | Membership_binding _
  | Sequence_splice _ | Enabledness_complement _ | Rewrite_dependent _ -> false

let request_key request =
  match request.kind with
  | Runtime_predicate_search _ | Runtime_predicate_truth_search _
  | Runtime_predicate_truth_decision _ | Runtime_enabledness _ ->
    key_of_kind request.kind
  | _ -> origin_key request.origin ^ "\000" ^ key_of_kind request.kind

let request registry request =
  let key =
    Digest.to_hex (Digest.string (request_key request))
  in
  match List.find_opt (fun entry -> entry.key = key) registry.entries with
  | Some entry -> entry.name
  | None ->
    let name = unique_helper_name registry (helper_base_name request) in
    let entry = { key; name; request } in
    registry.entries <- registry.entries @ [ entry ];
    entry.name

let requests registry =
  registry.entries |> List.map (fun entry -> entry.request)

let runtime_predicate_search_requests registry =
  registry.entries
  |> List.filter_map (fun entry ->
    match entry.request.kind with
    | Runtime_predicate_search request ->
      Some (entry.name, entry.request.origin, request)
    | _ -> None)

let runtime_predicate_truth_search_requests registry =
  registry.entries
  |> List.filter_map (fun entry ->
    match entry.request.kind with
    | Runtime_predicate_truth_search request ->
      Some (entry.name, entry.request.origin, request)
    | _ -> None)

let runtime_predicate_truth_decision_requests registry =
  registry.entries
  |> List.filter_map (fun entry ->
    match entry.request.kind with
    | Runtime_predicate_truth_decision request ->
      Some (entry.name, entry.request.origin, request)
    | _ -> None)

let runtime_enabledness_requests registry =
  registry.entries
  |> List.filter_map (fun entry ->
    match entry.request.kind with
    | Runtime_enabledness request ->
      Some (entry.name, entry.request.origin, request)
    | _ -> None)

let unmaterialized_diagnostics ~profile registry =
  registry.entries
  |> List.filter_map (fun entry ->
    if kind_has_materializer entry.request.kind then
      None
    else
      Some
        (Diagnostics.make
           ~category:Diagnostics.Unsupported
           ~origin:entry.request.origin
           ~constructor:"Helper/unmaterialized-request"
           ~enclosing:[ entry.name ]
           ~profile
           ~reason:
             (Printf.sprintf
                "helper request `%s` was registered, but this helper kind has no Maude materializer"
                (kind_name entry.request.kind))
           ~suggestion:
             "Do not register this helper until its source-preserving Maude equations/rules are implemented"
           ~source_echo:entry.request.reason
           ()))

let spectec_terminal = sort "SpectecTerminal"
let spectec_terminals = sort "SpectecTerminals"
let nat = sort "Nat"

let app name args =
  App (name, args)

let concat left right =
  app "_ _" [ left; right ]

let generated name origin node =
  Maude_ir.generated ~provenance:(Helper name) ~origin node

let helper_call_multi name sources captures =
  app name (sources @ List.map (fun capture -> Var capture.formal_var) captures)

let helper_call name first captures =
  helper_call_multi name [ first ] captures

let pair_split_result_op name = "pairSplit" ^ name
let pair_split_fail_op name = "pairSplit" ^ name ^ "Fail"
let pair_split_unzip_op name = name ^ "Unzip"
let pair_split_prepend_op name = name ^ "Prepend"

let concatn_chunks_result_op name = "concatnChunks" ^ name
let concatn_chunks_fail_op name = "concatnChunks" ^ name ^ "Fail"
let concatn_chunks_inverse_op name = name ^ "Inverse"
let concatn_chunks_prepend_op name = name ^ "Prepend"

let pair_split_sort name =
  sort ("PairSplit" ^ name)

let concatn_chunks_sort name =
  sort ("ConcatnChunks" ^ name)

let helper_call_from_tail name (map : iter_map) =
  helper_call name (Var map.source_tail_var) map.captures

let not_eps tail_var =
  BoolCond (app "_=/=_" [ Var tail_var; Const "eps" ])

let succ term =
  app "s_" [ term ]

let result_bound_conditions (map : iter_map) =
  let conditions =
    map.body_eq_conditions
    @ [ MatchCond (Var map.body_result_var, map.lowered_body) ]
  in
  let initial_bound =
    map.helper_head_var :: List.map (fun capture -> capture.formal_var) map.captures
  in
  match schedule_eq_conditions initial_bound conditions with
  | Some scheduled -> scheduled
  | None -> conditions

let result_bound_conditions_for
    ~initial_bound
    ~body_result_var
    ~lowered_body
    ~body_eq_conditions =
  let conditions = body_eq_conditions @ [ MatchCond (Var body_result_var, lowered_body) ] in
  match schedule_eq_conditions initial_bound conditions with
  | Some scheduled -> scheduled
  | None -> conditions

let output_item_term = function
  | Output_flat_terminal, body_result_var -> Var body_result_var
  | Output_nested_seq, body_result_var -> app "seq" [ Var body_result_var ]

let output_item_sort = function
  | Output_flat_terminal -> spectec_terminal
  | Output_nested_seq -> spectec_terminals

let source_item_term source_item_shape head =
  match source_item_shape with
  | Source_flat_terminal -> head
  | Source_nested_seq -> app "seq" [ head ]

let materialize_iter_map entry (map : iter_map) =
  let name = entry.name in
  let origin = entry.request.origin in
  let capture_sorts =
    map.captures |> List.map (fun capture -> sort_ref capture.sort)
  in
  let formal_captures =
    map.captures |> List.map (fun capture -> Var capture.formal_var)
  in
  let helper_on term =
    app name (term :: formal_captures)
  in
  let head = Var map.helper_head_var in
  let tail = Var map.source_tail_var in
  let out = output_item_term (map.output_item_shape, map.body_result_var) in
  let source_head = source_item_term map.source_item_shape head in
  let singleton_lhs = helper_on source_head in
  let recursive_lhs = helper_on (concat source_head tail) in
  let recursive_rhs = concat out (helper_call_from_tail name map) in
  let statement node = generated name origin node in
  [ statement
      (op name
         (sort_ref spectec_terminals :: capture_sorts)
         spectec_terminals)
  ; statement (var map.helper_head_var (sort_ref map.source_element_sort))
  ; statement (var map.source_tail_var (sort_ref spectec_terminals))
  ; statement (var map.body_result_var (sort_ref (output_item_sort map.output_item_shape)))
  ]
  @ (map.captures
     |> List.map (fun capture ->
       statement (var capture.formal_var (sort_ref capture.sort))))
  @ [ statement (ceq (helper_on (Const "eps")) (Const "eps") [])
    ; statement
        (ceq singleton_lhs out
           (result_bound_conditions map))
    ; statement
        (ceq recursive_lhs recursive_rhs
           (not_eps map.source_tail_var :: result_bound_conditions map))
    ]

let materialize_iter_zip_map entry (map : iter_zip_map) =
  let name = entry.name in
  let origin = entry.request.origin in
  let capture_sorts =
    map.captures |> List.map (fun capture -> sort_ref capture.sort)
  in
  let formal_captures =
    map.captures |> List.map (fun capture -> Var capture.formal_var)
  in
  let helper_on source_terms =
    app name (source_terms @ formal_captures)
  in
  let heads =
    map.sources
    |> List.map (fun (source : iter_zip_source) -> Var source.helper_head_var)
  in
  let tails =
    map.sources
    |> List.map (fun (source : iter_zip_source) -> Var source.source_tail_var)
  in
  let source_heads =
    List.map2
      (fun (source : iter_zip_source) head ->
        source_item_term source.source_item_shape head)
      map.sources
      heads
  in
  let recursive_sources =
    List.map2 concat source_heads tails
  in
  let out = output_item_term (map.output_item_shape, map.body_result_var) in
  let recursive_rhs =
    concat out (helper_call_multi name tails map.captures)
  in
  let result_conditions =
    result_bound_conditions_for
      ~initial_bound:
        ((map.sources |> List.map (fun (source : iter_zip_source) -> source.helper_head_var))
         @ List.map (fun capture -> capture.formal_var) map.captures)
      ~body_result_var:map.body_result_var
      ~lowered_body:map.lowered_body
      ~body_eq_conditions:map.body_eq_conditions
  in
  let recursive_conditions =
    List.map
      (fun (source : iter_zip_source) -> not_eps source.source_tail_var)
      map.sources
    @ result_conditions
  in
  let statement node = generated name origin node in
  [ statement
      (op name
         ((map.sources |> List.map (fun _ -> sort_ref spectec_terminals))
          @ capture_sorts)
         spectec_terminals)
  ]
  @ (map.sources
     |> List.concat_map (fun (source : iter_zip_source) ->
       [ statement (var source.helper_head_var (sort_ref source.source_element_sort))
       ; statement (var source.source_tail_var (sort_ref spectec_terminals))
       ]))
  @ [ statement (var map.body_result_var (sort_ref (output_item_sort map.output_item_shape))) ]
  @ (map.captures
     |> List.map (fun capture ->
       statement (var capture.formal_var (sort_ref capture.sort))))
  @ [ statement
        (ceq
           (helper_on (List.map (fun _ -> Const "eps") map.sources))
           (Const "eps")
           [])
    ; statement
        (ceq (helper_on source_heads) out result_conditions)
    ; statement
        (ceq (helper_on recursive_sources) recursive_rhs recursive_conditions)
    ]

let materialize_iter_listn_repeat entry (map : iter_listn) =
  let name = entry.name in
  let origin = entry.request.origin in
  let capture_sorts =
    map.captures |> List.map (fun capture -> sort_ref capture.sort)
  in
  let formal_captures =
    map.captures |> List.map (fun capture -> Var capture.formal_var)
  in
  let helper_on count =
    app name (count :: formal_captures)
  in
  let count = Var map.count_var in
  let out = output_item_term (map.output_item_shape, map.body_result_var) in
  let result_conditions =
    result_bound_conditions_for
      ~initial_bound:
        (map.count_var :: List.map (fun capture -> capture.formal_var) map.captures)
      ~body_result_var:map.body_result_var
      ~lowered_body:map.lowered_body
      ~body_eq_conditions:map.body_eq_conditions
  in
  let statement node = generated name origin node in
  [ statement (op name (sort_ref nat :: capture_sorts) spectec_terminals)
  ; statement (var map.count_var (sort_ref nat))
  ; statement (var map.body_result_var (sort_ref (output_item_sort map.output_item_shape)))
  ]
  @ (map.captures
     |> List.map (fun capture ->
       statement (var capture.formal_var (sort_ref capture.sort))))
  @ [ statement (ceq (helper_on (Const "0")) (Const "eps") [])
    ; statement
        (ceq
           (helper_on (succ count))
           (concat out (helper_on count))
           result_conditions)
    ]

let materialize_iter_listn_indexed entry (map : iter_listn) =
  match map.index_var with
  | None -> materialize_iter_listn_repeat entry map
  | Some index_var ->
    let name = entry.name in
    let origin = entry.request.origin in
    let capture_sorts =
      map.captures |> List.map (fun capture -> sort_ref capture.sort)
    in
    let formal_captures =
      map.captures |> List.map (fun capture -> Var capture.formal_var)
    in
    let helper_on count index =
      app name (count :: index :: formal_captures)
    in
    let count = Var map.count_var in
    let index = Var index_var in
    let out = output_item_term (map.output_item_shape, map.body_result_var) in
    let result_conditions =
      result_bound_conditions_for
        ~initial_bound:
          (map.count_var :: index_var
           :: List.map (fun capture -> capture.formal_var) map.captures)
        ~body_result_var:map.body_result_var
        ~lowered_body:map.lowered_body
        ~body_eq_conditions:map.body_eq_conditions
    in
    let statement node = generated name origin node in
    [ statement
        (op name
           (sort_ref nat :: sort_ref nat :: capture_sorts)
           spectec_terminals)
    ; statement (var map.count_var (sort_ref nat))
    ; statement (var index_var (sort_ref nat))
    ; statement (var map.body_result_var (sort_ref (output_item_sort map.output_item_shape)))
    ]
    @ (map.captures
       |> List.map (fun capture ->
         statement (var capture.formal_var (sort_ref capture.sort))))
    @ [ statement (ceq (helper_on (Const "0") index) (Const "eps") [])
      ; statement
          (ceq
             (helper_on (succ count) index)
             (concat out (helper_on count (succ index)))
             result_conditions)
      ]

let materialize_iter_listn entry (map : iter_listn) =
  match map.source_shape.mode with
  | Repeat_count -> materialize_iter_listn_repeat entry map
  | Indexed_from_zero -> materialize_iter_listn_indexed entry map

let materialize_iter_listn_source entry (map : iter_listn_source) =
  let name = entry.name in
  let origin = entry.request.origin in
  let capture_sorts =
    map.captures |> List.map (fun capture -> sort_ref capture.sort)
  in
  let formal_captures =
    map.captures |> List.map (fun capture -> Var capture.formal_var)
  in
  let helper_on count index source =
    app name (count :: index :: source :: formal_captures)
  in
  let count = Var map.count_var in
  let index = Var map.index_var in
  let head = Var map.helper_head_var in
  let tail = Var map.source_tail_var in
  let out = output_item_term (map.output_item_shape, map.body_result_var) in
  let source_head = source_item_term map.source_item_shape head in
  let recursive_lhs = helper_on (succ count) index (concat source_head tail) in
  let recursive_rhs = concat out (helper_on count (succ index) tail) in
  let result_conditions =
    result_bound_conditions_for
      ~initial_bound:
        (map.count_var :: map.index_var :: map.helper_head_var
         :: List.map (fun capture -> capture.formal_var) map.captures)
      ~body_result_var:map.body_result_var
      ~lowered_body:map.lowered_body
      ~body_eq_conditions:map.body_eq_conditions
  in
  let statement node = generated name origin node in
  [ statement
      (op name
         (sort_ref nat :: sort_ref nat :: sort_ref spectec_terminals
          :: capture_sorts)
         spectec_terminals)
  ; statement (var map.count_var (sort_ref nat))
  ; statement (var map.index_var (sort_ref nat))
  ; statement (var map.helper_head_var (sort_ref map.source_element_sort))
  ; statement (var map.source_tail_var (sort_ref spectec_terminals))
  ; statement (var map.body_result_var (sort_ref (output_item_sort map.output_item_shape)))
  ]
  @ (map.captures
     |> List.map (fun capture ->
       statement (var capture.formal_var (sort_ref capture.sort))))
  @ [ statement
        (ceq
           (helper_on (Const "0") index (Const "eps"))
           (Const "eps")
           [])
    ; statement
        (ceq recursive_lhs recursive_rhs result_conditions)
    ]

let materialize_iter_premise_opt_bool entry (prem : iter_premise_opt_bool) =
  let name = entry.name in
  let origin = entry.request.origin in
  let capture_sorts =
    prem.captures |> List.map (fun capture -> sort_ref capture.sort)
  in
  let formal_captures =
    prem.captures |> List.map (fun capture -> Var capture.formal_var)
  in
  let helper_on source =
    app name (source :: formal_captures)
  in
  let head = Var prem.helper_head_var in
  let tail = Var prem.source_tail_var in
  let body_result = Var prem.body_result_var in
  let result_conditions =
    result_bound_conditions_for
      ~initial_bound:
        (prem.helper_head_var
         :: List.map (fun capture -> capture.formal_var) prem.captures)
      ~body_result_var:prem.body_result_var
      ~lowered_body:prem.lowered_body
      ~body_eq_conditions:prem.body_eq_conditions
  in
  let statement node = generated name origin node in
  [ statement
      (op name
         (sort_ref spectec_terminals :: capture_sorts)
         (sort "Bool"))
  ; statement (var prem.helper_head_var (sort_ref prem.source_element_sort))
  ; statement (var prem.source_tail_var (sort_ref spectec_terminals))
  ; statement (var prem.body_result_var (sort_ref (sort "Bool")))
  ]
  @ (prem.captures
     |> List.map (fun capture ->
       statement (var capture.formal_var (sort_ref capture.sort))))
  @ [ statement (ceq (helper_on (Const "eps")) (Const "true") [])
    ; statement
        (ceq (helper_on head) body_result result_conditions)
    ; statement
        (ceq
           (helper_on (concat head tail))
           (Const "false")
           [ not_eps prem.source_tail_var ])
    ]

let materialize_iter_premise_list_bool entry (prem : iter_premise_list_bool) =
  let name = entry.name in
  let origin = entry.request.origin in
  let capture_sorts =
    prem.captures |> List.map (fun capture -> sort_ref capture.sort)
  in
  let formal_captures =
    prem.captures |> List.map (fun capture -> Var capture.formal_var)
  in
  let helper_on source =
    app name (source :: formal_captures)
  in
  let head = Var prem.helper_head_var in
  let tail = Var prem.source_tail_var in
  let recursive_lhs = helper_on (concat head tail) in
  let recursive_rhs = helper_on tail in
  let body_conditions = prem.body_eq_conditions in
  let recursive_conditions =
    not_eps prem.source_tail_var :: body_conditions
  in
  let statement node = generated name origin node in
  [ statement
      (op name
         (sort_ref spectec_terminals :: capture_sorts)
         (sort "Bool"))
  ; statement (var prem.helper_head_var (sort_ref prem.source_element_sort))
  ; statement (var prem.source_tail_var (sort_ref spectec_terminals))
  ]
  @ (prem.captures
     |> List.map (fun capture ->
       statement (var capture.formal_var (sort_ref capture.sort))))
  @ [ statement (ceq (helper_on (Const "eps")) (Const "true") [])
    ; statement (ceq (helper_on head) (Const "true") body_conditions)
    ; statement (ceq recursive_lhs recursive_rhs recursive_conditions)
    ]

let materialize_iter_premise_exists_bool entry (prem : iter_premise_exists_bool) =
  let name = entry.name in
  let origin = entry.request.origin in
  let capture_sorts =
    prem.captures |> List.map (fun capture -> sort_ref capture.sort)
  in
  let formal_captures =
    prem.captures |> List.map (fun capture -> Var capture.formal_var)
  in
  let helper_on source =
    app name (source :: formal_captures)
  in
  let head = Var prem.helper_head_var in
  let tail = Var prem.source_tail_var in
  let recursive_lhs = helper_on (concat head tail) in
  let recursive_rhs = helper_on tail in
  let body_conditions =
    match
      schedule_eq_conditions
        (prem.helper_head_var
         :: List.map (fun capture -> capture.formal_var) prem.captures)
        prem.body_eq_conditions
    with
    | Some scheduled -> scheduled
    | None -> prem.body_eq_conditions
  in
  let statement node = generated name origin node in
  [ statement
      (op name
         (sort_ref spectec_terminals :: capture_sorts)
         (sort "Bool"))
  ; statement (var prem.helper_head_var (sort_ref prem.source_element_sort))
  ; statement (var prem.source_tail_var (sort_ref spectec_terminals))
  ]
  @ (prem.captures
     |> List.map (fun capture ->
     statement (var capture.formal_var (sort_ref capture.sort))))
  @ [ statement (eq (helper_on (Const "eps")) (Const "false"))
    ; statement (ceq (helper_on head) (Const "true") body_conditions)
    ; statement
        (ceq
           recursive_lhs
           (Const "true")
           [ BoolCond recursive_rhs ])
    ]

let materialize_iter_premise_zip_bool entry (prem : iter_premise_zip_bool) =
  let name = entry.name in
  let origin = entry.request.origin in
  let capture_sorts =
    prem.captures |> List.map (fun capture -> sort_ref capture.sort)
  in
  let formal_captures =
    prem.captures |> List.map (fun capture -> Var capture.formal_var)
  in
  let helper_on sources =
    app name (sources @ formal_captures)
  in
  let heads =
    prem.sources
    |> List.map (fun (source : iter_zip_source) -> Var source.helper_head_var)
  in
  let tails =
    prem.sources
    |> List.map (fun (source : iter_zip_source) -> Var source.source_tail_var)
  in
  let source_heads =
    List.map2
      (fun (source : iter_zip_source) head ->
        source_item_term source.source_item_shape head)
      prem.sources
      heads
  in
  let recursive_sources = List.map2 concat source_heads tails in
  let body_conditions =
    match
      schedule_eq_conditions
        ((prem.sources
          |> List.map (fun (source : iter_zip_source) -> source.helper_head_var))
         @ List.map (fun capture -> capture.formal_var) prem.captures)
        prem.body_eq_conditions
    with
    | Some conditions -> conditions
    | None -> prem.body_eq_conditions
  in
  let recursive_conditions =
    (prem.sources
     |> List.map (fun (source : iter_zip_source) -> not_eps source.source_tail_var))
    @ body_conditions
  in
  let statement node = generated name origin node in
  [ statement
      (op name
         ((prem.sources |> List.map (fun _ -> sort_ref spectec_terminals))
          @ capture_sorts)
         (sort "Bool"))
  ]
  @ (prem.sources
     |> List.concat_map (fun (source : iter_zip_source) ->
       [ statement (var source.helper_head_var (sort_ref source.source_element_sort))
       ; statement (var source.source_tail_var (sort_ref spectec_terminals))
       ]))
  @ (prem.captures
     |> List.map (fun capture ->
       statement (var capture.formal_var (sort_ref capture.sort))))
  @ [ statement
        (ceq
           (helper_on (List.map (fun _ -> Const "eps") prem.sources))
           (Const "true")
           [])
    ; statement (ceq (helper_on source_heads) (Const "true") body_conditions)
    ; statement
        (ceq
           (helper_on recursive_sources)
           (helper_on tails)
           recursive_conditions)
    ]

let materialize_iter_pattern_zip entry (pattern : iter_pattern_zip) =
  let name = entry.name in
  let origin = entry.request.origin in
  let helper_on subject =
    app name [ subject ]
  in
  let tuple_of_sources sources =
    let wrapped = List.map (fun source -> app "seq" [ source ]) sources in
    let tuple_items =
      match wrapped with
      | [] -> Const "eps"
      | hd :: tl -> List.fold_left concat hd tl
    in
    app "tuple" [ tuple_items ]
  in
  let subject_tail = Var pattern.subject_tail_var in
  let source_heads =
    pattern.sources
    |> List.map (fun (source : iter_pattern_zip_source) ->
      source_item_term source.source_item_shape source.source_head_term)
  in
  let source_tails =
    pattern.sources
    |> List.map (fun (source : iter_pattern_zip_source) -> Var source.source_tail_var)
  in
  let recursive_lhs =
    helper_on (concat pattern.subject_item_term subject_tail)
  in
  let recursive_rhs = tuple_of_sources (List.map2 concat source_heads source_tails) in
  let tail_tuple = tuple_of_sources source_tails in
  let initial_bound =
    term_vars pattern.subject_item_term
    @ term_vars subject_tail
    @ List.concat_map term_vars source_heads
  in
  let body_conditions =
    match schedule_eq_conditions initial_bound pattern.body_eq_conditions with
    | Some conditions -> conditions
    | None -> pattern.body_eq_conditions
  in
  let recursive_conditions =
    not_eps pattern.subject_tail_var
    :: body_conditions
    @ [ MatchCond (tail_tuple, helper_on subject_tail) ]
  in
  let statement node = generated name origin node in
  [ statement
      (op name
         [ sort_ref spectec_terminals ]
         spectec_terminal)
  ; statement (var pattern.subject_tail_var (sort_ref spectec_terminals))
  ]
  @ (pattern.sources
     |> List.map (fun (source : iter_pattern_zip_source) ->
       statement (var source.source_tail_var (sort_ref spectec_terminals))))
  @ [ statement
        (ceq
           (helper_on (Const "eps"))
           (tuple_of_sources (List.map (fun _ -> Const "eps") pattern.sources))
           [])
    ; statement
        (ceq
           (helper_on pattern.subject_item_term)
           (tuple_of_sources source_heads)
           body_conditions)
    ; statement
        (ceq recursive_lhs recursive_rhs recursive_conditions)
    ]

let materialize_inverse_pair_split entry (split : inverse_pair_split) =
  let name = entry.name in
  let origin = entry.request.origin in
  let result_name = pair_split_result_op name in
  let fail_name = pair_split_fail_op name in
  let unzip_name = pair_split_unzip_op name in
  let prepend_name = pair_split_prepend_op name in
  let split_sort = pair_split_sort name in
  let left_head = Var split.left_head_var in
  let right_head = Var split.right_head_var in
  let left_stream = Var split.left_stream_var in
  let right_stream = Var split.right_stream_var in
  let tail = Var split.source_tail_var in
  let pair = concat left_head right_head in
  let recursive_subject = concat pair tail in
  let result left right = app result_name [ left; right ] in
  let unzip source = app unzip_name [ source ] in
  let prepend left right split = app prepend_name [ left; right; split ] in
  let fail = Const fail_name in
  let statement node = generated name origin node in
  [ statement (sort_decl split_sort)
  ; statement
      (op result_name
         [ sort_ref spectec_terminals; sort_ref spectec_terminals ]
         split_sort
         ~attrs:[ Ctor ])
  ; statement (op fail_name [] split_sort ~attrs:[ Ctor ])
  ; statement (op unzip_name [ sort_ref spectec_terminals ] split_sort)
  ; statement
      (op prepend_name
         [ sort_ref spectec_terminal
         ; sort_ref spectec_terminal
         ; sort_ref split_sort
         ]
         split_sort)
  ; statement (var split.left_head_var (sort_ref spectec_terminal))
  ; statement (var split.right_head_var (sort_ref spectec_terminal))
  ; statement (var split.left_stream_var (sort_ref spectec_terminals))
  ; statement (var split.right_stream_var (sort_ref spectec_terminals))
  ; statement (var split.source_tail_var (sort_ref spectec_terminals))
  ; statement (eq (unzip (Const "eps")) (result (Const "eps") (Const "eps")))
  ; statement (eq (unzip left_head) fail)
  ; statement
      (eq
         (unzip recursive_subject)
         (prepend left_head right_head (unzip tail)))
  ; statement
      (eq
         (prepend left_head right_head (result left_stream right_stream))
         (result (concat left_head left_stream) (concat right_head right_stream)))
  ; statement (eq (prepend left_head right_head fail) fail)
  ]

let materialize_inverse_concatn_chunks entry (inverse : inverse_concatn_chunks) =
  let name = entry.name in
  let origin = entry.request.origin in
  let result_name = concatn_chunks_result_op name in
  let fail_name = concatn_chunks_fail_op name in
  let inverse_name = concatn_chunks_inverse_op name in
  let prepend_name = concatn_chunks_prepend_op name in
  let result_sort = concatn_chunks_sort name in
  let target_head = Var inverse.target_head_var in
  let target_stream = Var inverse.target_stream_var in
  let bytes = Var inverse.bytes_var in
  let bytes_head = Var inverse.bytes_head_var in
  let bytes_tail = Var inverse.bytes_tail_var in
  let width = Var inverse.width_var in
  let count_tail = Var inverse.count_tail_var in
  let chunk = Var inverse.chunk_var in
  let capture_vars =
    inverse.captures |> List.map (fun capture -> Var capture.formal_var)
  in
  let helper source width count = app inverse_name (capture_vars @ [ source; width; count ]) in
  let result stream = app result_name [ stream ] in
  let fail = Const fail_name in
  let prepend head tail = app prepend_name [ head; tail ] in
  let source_nonempty = concat bytes_head bytes_tail in
  let current_chunk = app "slice" [ bytes; Const "0"; width ] in
  let source_tail = app "drop" [ width; bytes ] in
  let inverse_call = app inverse.inverse_op inverse.inverse_call_formals in
  let original_call = app inverse.bytes_op inverse.bytes_call_formals in
  let statement node = generated name origin node in
  [ statement (sort_decl result_sort)
  ; statement
      (op result_name [ sort_ref spectec_terminals ] result_sort ~attrs:[ Ctor ])
  ; statement (op fail_name [] result_sort ~attrs:[ Ctor ])
  ; statement
      (op inverse_name
         ((inverse.captures |> List.map (fun capture -> sort_ref capture.sort))
          @ [ sort_ref spectec_terminals; sort_ref nat; sort_ref nat ])
         result_sort)
  ; statement
      (op prepend_name
         [ sort_ref spectec_terminal; sort_ref result_sort ]
         result_sort)
  ]
  @ (inverse.captures
     |> List.map (fun capture -> statement (var capture.formal_var (sort_ref capture.sort))))
  @ [ statement (var inverse.target_head_var (sort_ref spectec_terminal))
    ; statement (var inverse.target_stream_var (sort_ref spectec_terminals))
    ; statement (var inverse.bytes_var (sort_ref spectec_terminals))
    ; statement (var inverse.bytes_head_var (sort_ref spectec_terminal))
    ; statement (var inverse.bytes_tail_var (sort_ref spectec_terminals))
    ; statement (var inverse.width_var (sort_ref nat))
    ; statement (var inverse.count_tail_var (sort_ref nat))
    ; statement (var inverse.chunk_var (sort_ref spectec_terminals))
    ; statement
        (eq
           (helper (Const "eps") width (Const "0"))
           (result (Const "eps")))
    ; statement (eq (helper source_nonempty width (Const "0")) fail)
    ; statement
        (ceq
           (helper bytes width (succ count_tail))
           (prepend target_head (helper source_tail width count_tail))
           [ MatchCond (chunk, current_chunk)
           ; MatchCond (target_head, inverse_call)
           ; EqCond (original_call, chunk)
           ])
    ; statement
        (eq
           (prepend target_head (result target_stream))
           (result (concat target_head target_stream)))
    ; statement (eq (prepend target_head fail) fail)
    ]

let materialize_optional_map_inverse entry (inverse : optional_map_inverse) =
  let name = entry.name in
  let origin = entry.request.origin in
  let capture_sorts =
    inverse.captures |> List.map (fun capture -> sort_ref capture.sort)
  in
  let formal_captures =
    inverse.captures |> List.map (fun capture -> Var capture.formal_var)
  in
  let helper_on term =
    app name (term :: formal_captures)
  in
  let head = Var inverse.helper_head_var in
  let result_conditions =
    match
      schedule_eq_conditions
        (inverse.helper_head_var
         :: List.map (fun capture -> capture.formal_var) inverse.captures)
        inverse.body_eq_conditions
    with
    | Some scheduled -> scheduled
    | None -> inverse.body_eq_conditions
  in
  let statement node = generated name origin node in
  [ statement
      (op name
         (sort_ref spectec_terminals :: capture_sorts)
         spectec_terminals)
  ; statement (var inverse.helper_head_var (sort_ref inverse.source_element_sort))
  ]
  @ (inverse.captures
     |> List.map (fun capture ->
       statement (var capture.formal_var (sort_ref capture.sort))))
  @ [ statement (eq (helper_on (Const "eps")) (Const "eps"))
    ; statement (ceq (helper_on inverse.lowered_body) head result_conditions)
    ]

let materialize_entry entry =
  match entry.request.kind with
  | Iter_map map -> materialize_iter_map entry map
  | Iter_zip_map map -> materialize_iter_zip_map entry map
  | Iter_listn map -> materialize_iter_listn entry map
  | Iter_listn_source map -> materialize_iter_listn_source entry map
  | Iter_premise_opt_bool prem -> materialize_iter_premise_opt_bool entry prem
  | Iter_premise_list_bool prem -> materialize_iter_premise_list_bool entry prem
  | Iter_premise_exists_bool prem -> materialize_iter_premise_exists_bool entry prem
  | Iter_premise_zip_bool prem -> materialize_iter_premise_zip_bool entry prem
  | Iter_pattern_zip pattern -> materialize_iter_pattern_zip entry pattern
  | Inverse_pair_split split -> materialize_inverse_pair_split entry split
  | Inverse_concatn_chunks inverse -> materialize_inverse_concatn_chunks entry inverse
  | Optional_map_inverse inverse -> materialize_optional_map_inverse entry inverse
  | Optional_branch _ | List1_guard _ | Listn_indexed _ | Membership_binding _
  | Sequence_splice _ | Enabledness_complement _ | Rewrite_dependent _
  | Runtime_predicate_search _ | Runtime_predicate_truth_search _
  | Runtime_predicate_truth_decision _ | Runtime_enabledness _ -> []

let materialize registry =
  registry.entries |> List.concat_map materialize_entry
