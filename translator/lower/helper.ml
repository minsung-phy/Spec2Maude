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

type request_kind =
  | Iter_map of iter_map
  | Iter_zip_map of iter_zip_map
  | Iter_listn of iter_listn
  | Iter_listn_source of iter_listn_source
  | Iter_premise_opt_bool of iter_premise_opt_bool
  | Optional_branch of { shape : string }
  | List1_guard of { shape : string }
  | Listn_indexed of { shape : string }
  | Membership_binding of { shape : string }
  | Sequence_splice of { shape : string }
  | Enabledness_complement of { shape : string }
  | Rewrite_dependent of { shape : string }

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
        let bound = add_unique (condition_bound_vars chosen) bound in
        loop bound (chosen :: scheduled) remaining)
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

let origin_key origin =
  String.concat
    "\000"
    [ Origin.source_location origin
    ; Origin.path origin
    ; origin.Origin.ast_constructor
    ]

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
  | Optional_branch { shape } -> "optional-branch:" ^ shape
  | List1_guard { shape } -> "list1-guard:" ^ shape
  | Listn_indexed { shape } -> "listn-indexed:" ^ shape
  | Membership_binding { shape } -> "membership-binding:" ^ shape
  | Sequence_splice { shape } -> "sequence-splice:" ^ shape
  | Enabledness_complement { shape } -> "enabledness-complement:" ^ shape
  | Rewrite_dependent { shape } -> "rewrite-dependent:" ^ shape

let helper_name key =
  "helperitermapx" ^ Digest.to_hex (Digest.string key)

let request registry request =
  let key =
    Digest.to_hex
      (Digest.string (origin_key request.origin ^ "\000" ^ key_of_kind request.kind))
  in
  match List.find_opt (fun entry -> entry.key = key) registry.entries with
  | Some entry -> entry.name
  | None ->
    let entry = { key; name = helper_name key; request } in
    registry.entries <- registry.entries @ [ entry ];
    entry.name

let requests registry =
  registry.entries |> List.map (fun entry -> entry.request)

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
      ~initial_bound:(List.map (fun capture -> capture.formal_var) map.captures)
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
          (index_var :: List.map (fun capture -> capture.formal_var) map.captures)
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
        (map.index_var :: map.helper_head_var
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

let materialize_entry entry =
  match entry.request.kind with
  | Iter_map map -> materialize_iter_map entry map
  | Iter_zip_map map -> materialize_iter_zip_map entry map
  | Iter_listn map -> materialize_iter_listn entry map
  | Iter_listn_source map -> materialize_iter_listn_source entry map
  | Iter_premise_opt_bool prem -> materialize_iter_premise_opt_bool entry prem
  | Optional_branch _ | List1_guard _ | Listn_indexed _ | Membership_binding _
  | Sequence_splice _ | Enabledness_complement _ | Rewrite_dependent _ -> []

let materialize registry =
  registry.entries |> List.concat_map materialize_entry
