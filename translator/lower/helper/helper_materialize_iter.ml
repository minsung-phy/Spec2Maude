open Maude_ir
module Request = Helper_request
open Helper_emission

let term_vars term =
  let rec loop acc = function
    | Var name -> name :: acc
    | Const _ | Qid _ -> acc
    | App (_, args) -> List.fold_left loop acc args
  in
  loop [] term |> List.sort_uniq String.compare

let helper_call_multi name sources captures =
  app name
    (sources @ List.map (fun capture -> Var capture.Request.formal_var) captures)

let helper_call name first captures =
  helper_call_multi name [ first ] captures

let helper_call_from_tail name (map : Request.iter_map) =
  helper_call name (Var map.source_tail_var) map.captures

let result_bound_conditions_for
    ~initial_bound
    ~body_result_var
    ~lowered_body
    ~body_eq_conditions =
  let conditions =
    body_eq_conditions @ [ MatchCond (Var body_result_var, lowered_body) ]
  in
  match Condition_schedule.schedule_eq_conditions initial_bound conditions with
  | Some scheduled -> scheduled
  | None -> conditions

let result_bound_conditions (map : Request.iter_map) =
  result_bound_conditions_for
    ~initial_bound:
      (map.helper_head_var
       :: List.map (fun capture -> capture.Request.formal_var) map.captures)
    ~body_result_var:map.body_result_var
    ~lowered_body:map.lowered_body
    ~body_eq_conditions:map.body_eq_conditions

let output_item_term = function
  | Request.Output_flat_terminal, body_result_var -> Var body_result_var
  | Request.Output_nested_seq, body_result_var -> app "seq" [ Var body_result_var ]

let output_item_sort = function
  | Request.Output_flat_terminal -> spectec_terminal
  | Request.Output_nested_seq -> spectec_terminals

let source_item_term source_item_shape head =
  match source_item_shape with
  | Request.Source_flat_terminal -> head
  | Request.Source_nested_seq -> app "seq" [ head ]

let capture_variables captures =
  captures
  |> List.map (fun capture -> capture.Request.formal_var, sort_ref capture.Request.sort)

let source_variables sources =
  sources
  |> List.concat_map (fun (source : Request.iter_zip_source) ->
    [ source.helper_head_var, sort_ref source.source_element_sort
    ; source.source_tail_var, sort_ref spectec_terminals
    ])

let binding_output_variables outputs =
  outputs
  |> List.concat_map (fun (output : Request.iter_premise_binding_output) ->
    [ output.helper_head_var, sort_ref output.source_element_sort
    ; output.source_tail_var, sort_ref spectec_terminals
    ])

let materialize_iter_map entry (map : Request.iter_map) =
  let name = entry.Helper_registry.name in
  let origin = entry.request.Request.origin in
  let capture_sorts =
    map.captures |> List.map (fun capture -> sort_ref capture.Request.sort)
  in
  let formal_captures =
    map.captures |> List.map (fun capture -> Var capture.Request.formal_var)
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
  ]
  @ variable_declarations statement
      ([ map.helper_head_var, sort_ref map.source_element_sort
       ; map.source_tail_var, sort_ref spectec_terminals
       ; map.body_result_var, sort_ref (output_item_sort map.output_item_shape)
       ] @ capture_variables map.captures)
  @ [ statement (ceq (helper_on (Const "eps")) (Const "eps") [])
    ; statement
        (ceq singleton_lhs out
           (result_bound_conditions map))
    ; statement
        (ceq recursive_lhs recursive_rhs
           (not_eps map.source_tail_var :: result_bound_conditions map))
    ]

let materialize_iter_zip_map entry (map : Request.iter_zip_map) =
  let name = entry.Helper_registry.name in
  let origin = entry.request.Request.origin in
  let capture_sorts =
    map.captures |> List.map (fun capture -> sort_ref capture.Request.sort)
  in
  let formal_captures =
    map.captures |> List.map (fun capture -> Var capture.Request.formal_var)
  in
  let helper_on source_terms =
    app name (source_terms @ formal_captures)
  in
  let heads =
    map.sources
    |> List.map (fun (source : Request.iter_zip_source) -> Var source.helper_head_var)
  in
  let tails =
    map.sources
    |> List.map (fun (source : Request.iter_zip_source) -> Var source.source_tail_var)
  in
  let source_heads =
    List.map2
      (fun (source : Request.iter_zip_source) head ->
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
        ((map.sources |> List.map (fun (source : Request.iter_zip_source) -> source.helper_head_var))
         @ List.map (fun capture -> capture.Request.formal_var) map.captures)
      ~body_result_var:map.body_result_var
      ~lowered_body:map.lowered_body
      ~body_eq_conditions:map.body_eq_conditions
  in
  let recursive_conditions =
    List.map
      (fun (source : Request.iter_zip_source) -> not_eps source.source_tail_var)
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
  @ variable_declarations statement
      (source_variables map.sources
       @ [ map.body_result_var, sort_ref (output_item_sort map.output_item_shape) ]
       @ capture_variables map.captures)
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

let materialize_iter_listn_repeat entry (map : Request.iter_listn) =
  let name = entry.Helper_registry.name in
  let origin = entry.request.Request.origin in
  let capture_sorts =
    map.captures |> List.map (fun capture -> sort_ref capture.Request.sort)
  in
  let formal_captures =
    map.captures |> List.map (fun capture -> Var capture.Request.formal_var)
  in
  let helper_on count =
    app name (count :: formal_captures)
  in
  let count = Var map.count_var in
  let out = output_item_term (map.output_item_shape, map.body_result_var) in
  let result_conditions =
    result_bound_conditions_for
      ~initial_bound:
        (map.count_var :: List.map (fun capture -> capture.Request.formal_var) map.captures)
      ~body_result_var:map.body_result_var
      ~lowered_body:map.lowered_body
      ~body_eq_conditions:map.body_eq_conditions
  in
  let statement node = generated name origin node in
  [ statement (op name (sort_ref nat :: capture_sorts) spectec_terminals) ]
  @ variable_declarations statement
      ([ map.count_var, sort_ref nat
       ; map.body_result_var, sort_ref (output_item_sort map.output_item_shape)
       ] @ capture_variables map.captures)
  @ [ statement (ceq (helper_on (Const "0")) (Const "eps") [])
    ; statement
        (ceq
           (helper_on (succ count))
           (concat out (helper_on count))
           result_conditions)
    ]

let materialize_iter_listn_indexed entry (map : Request.iter_listn) =
  match map.index_var with
  | None -> materialize_iter_listn_repeat entry map
  | Some index_var ->
    let name = entry.Helper_registry.name in
    let origin = entry.request.Request.origin in
    let capture_sorts =
      map.captures |> List.map (fun capture -> sort_ref capture.Request.sort)
    in
    let formal_captures =
      map.captures |> List.map (fun capture -> Var capture.Request.formal_var)
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
           :: List.map (fun capture -> capture.Request.formal_var) map.captures)
        ~body_result_var:map.body_result_var
        ~lowered_body:map.lowered_body
        ~body_eq_conditions:map.body_eq_conditions
    in
    let statement node = generated name origin node in
    [ statement
        (op name
           (sort_ref nat :: sort_ref nat :: capture_sorts)
           spectec_terminals)
    ]
    @ variable_declarations statement
        ([ map.count_var, sort_ref nat
         ; index_var, sort_ref nat
         ; map.body_result_var, sort_ref (output_item_sort map.output_item_shape)
         ] @ capture_variables map.captures)
    @ [ statement (ceq (helper_on (Const "0") index) (Const "eps") [])
      ; statement
          (ceq
             (helper_on (succ count) index)
             (concat out (helper_on count (succ index)))
             result_conditions)
      ]

let materialize_iter_listn entry (map : Request.iter_listn) =
  match map.source_shape.mode with
  | Request.Repeat_count -> materialize_iter_listn_repeat entry map
  | Request.Indexed_from_zero -> materialize_iter_listn_indexed entry map

let materialize_iter_listn_source entry (map : Request.iter_listn_source) =
  let name = entry.Helper_registry.name in
  let origin = entry.request.Request.origin in
  let capture_sorts =
    map.captures |> List.map (fun capture -> sort_ref capture.Request.sort)
  in
  let formal_captures =
    map.captures |> List.map (fun capture -> Var capture.Request.formal_var)
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
         :: List.map (fun capture -> capture.Request.formal_var) map.captures)
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
  ]
  @ variable_declarations statement
      ([ map.count_var, sort_ref nat
       ; map.index_var, sort_ref nat
       ; map.helper_head_var, sort_ref map.source_element_sort
       ; map.source_tail_var, sort_ref spectec_terminals
       ; map.body_result_var, sort_ref (output_item_sort map.output_item_shape)
       ] @ capture_variables map.captures)
  @ [ statement
        (ceq
           (helper_on (Const "0") index (Const "eps"))
           (Const "eps")
           [])
    ; statement
        (ceq recursive_lhs recursive_rhs result_conditions)
    ]

let materialize_iter_premise_opt_bool entry (prem : Request.iter_premise_opt_bool) =
  let name = entry.Helper_registry.name in
  let origin = entry.request.Request.origin in
  let capture_sorts =
    prem.captures |> List.map (fun capture -> sort_ref capture.Request.sort)
  in
  let formal_captures =
    prem.captures |> List.map (fun capture -> Var capture.Request.formal_var)
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
         :: List.map (fun capture -> capture.Request.formal_var) prem.captures)
      ~body_result_var:prem.body_result_var
      ~lowered_body:prem.lowered_body
      ~body_eq_conditions:prem.body_eq_conditions
  in
  let statement node = generated name origin node in
  [ statement
      (op name
         (sort_ref spectec_terminals :: capture_sorts)
         (sort "Bool"))
  ]
  @ variable_declarations statement
      ([ prem.helper_head_var, sort_ref prem.source_element_sort
       ; prem.source_tail_var, sort_ref spectec_terminals
       ; prem.body_result_var, sort_ref (sort "Bool")
       ] @ capture_variables prem.captures)
  @ [ statement (ceq (helper_on (Const "eps")) (Const "true") [])
    ; statement
        (ceq (helper_on head) body_result result_conditions)
    ; statement
        (ceq
           (helper_on (concat head tail))
           (Const "false")
           [ not_eps prem.source_tail_var ])
    ]

let materialize_iter_premise_list_bool entry (prem : Request.iter_premise_list_bool) =
  let name = entry.Helper_registry.name in
  let origin = entry.request.Request.origin in
  let capture_sorts =
    prem.captures |> List.map (fun capture -> sort_ref capture.Request.sort)
  in
  let formal_captures =
    prem.captures |> List.map (fun capture -> Var capture.Request.formal_var)
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
  ]
  @ variable_declarations statement
      ([ prem.helper_head_var, sort_ref prem.source_element_sort
       ; prem.source_tail_var, sort_ref spectec_terminals
       ] @ capture_variables prem.captures)
  @ [ statement (ceq (helper_on (Const "eps")) (Const "true") [])
    ; statement (ceq (helper_on head) (Const "true") body_conditions)
    ; statement (ceq recursive_lhs recursive_rhs recursive_conditions)
    ]

let materialize_iter_premise_list_rule entry (prem : Request.iter_premise_list_rule) =
  let name = entry.Helper_registry.name in
  let origin = entry.request.Request.origin in
  let result_sort = sort ("IterPremiseRule" ^ Naming.sort_token name ^ "Conf") in
  let ok = Naming.helper_companion ~role:"premise-all-ok" name in
  let capture_sorts =
    prem.captures |> List.map (fun capture -> sort_ref capture.Request.sort)
  in
  let formal_captures =
    prem.captures |> List.map (fun capture -> Var capture.Request.formal_var)
  in
  let helper_on source = app name (source :: formal_captures) in
  let head = Var prem.helper_head_var in
  let tail = Var prem.source_tail_var in
  let conditions = prem.body_conditions @ [ RewriteCond (helper_on tail, Const ok) ] in
  let statement node = generated name origin node in
  [ statement (sort_decl result_sort)
  ; statement
      (op name
         (sort_ref spectec_terminals :: capture_sorts)
         result_sort
         ~attrs:[ Frozen (List.init (1 + List.length capture_sorts) (( + ) 1)) ])
  ; statement (op ok [] result_sort ~attrs:[ Ctor ])
  ]
  @ variable_declarations statement
      ([ prem.helper_head_var, sort_ref prem.source_element_sort
       ; prem.source_tail_var, sort_ref spectec_terminals
       ] @ capture_variables prem.captures)
  @ [ statement (rl (helper_on (Const "eps")) (Const ok))
    ; statement
        (crl
           (helper_on (concat head tail))
           (Const ok)
           conditions)
    ]

let materialize_iter_premise_zip_binding
    entry
    (prem : Request.iter_premise_zip_binding)
  =
  let name = entry.Helper_registry.name in
  let origin = entry.request.Request.origin in
  let capture_sorts = List.map (fun capture -> sort_ref capture.Request.sort) prem.captures in
  let formal_captures = List.map (fun capture -> Var capture.Request.formal_var) prem.captures in
  let helper_on sources = app name (sources @ formal_captures) in
  let source_heads =
    prem.sources
    |> List.map (fun (source : Request.iter_zip_source) ->
      source_item_term source.source_item_shape (Var source.helper_head_var))
  in
  let source_tails =
    List.map (fun (source : Request.iter_zip_source) -> Var source.source_tail_var) prem.sources
  in
  let recursive_sources = List.map2 concat source_heads source_tails in
  let output_heads =
    prem.outputs
    |> List.map (fun (output : Request.iter_premise_binding_output) ->
      source_item_term output.source_item_shape (Var output.helper_head_var))
  in
  let output_tails =
    List.map
      (fun (output : Request.iter_premise_binding_output) -> Var output.source_tail_var)
      prem.outputs
  in
  let tuple_of_sequences sequences =
    let items = List.map (fun sequence -> app "seq" [ sequence ]) sequences in
    let items =
      match items with
      | [] -> Const "eps"
      | head :: tail -> List.fold_left concat head tail
    in
    app "tuple" [ items ]
  in
  let body_conditions = prem.body_eq_conditions in
  let recursive_conditions =
    List.map
      (fun (source : Request.iter_zip_source) -> not_eps source.source_tail_var)
      prem.sources
    @ body_conditions
    @ [ MatchCond
          ( tuple_of_sequences output_tails
          , helper_on source_tails )
      ]
  in
  let statement node = generated name origin node in
  [ statement
      (op name
         ((List.map (fun _ -> sort_ref spectec_terminals) prem.sources)
          @ capture_sorts)
         spectec_terminal)
  ]
  @ variable_declarations statement
      (source_variables prem.sources
       @ binding_output_variables prem.outputs
       @ capture_variables prem.captures)
  @ [ statement
        (ceq
           (helper_on (List.map (fun _ -> Const "eps") prem.sources))
           (tuple_of_sequences (List.map (fun _ -> Const "eps") prem.outputs))
           [])
    ; statement
        (ceq
           (helper_on source_heads)
           (tuple_of_sequences output_heads)
           body_conditions)
    ; statement
        (ceq
           (helper_on recursive_sources)
           (tuple_of_sequences (List.map2 concat output_heads output_tails))
           recursive_conditions)
    ]

let materialize_iter_premise_exists_bool entry (prem : Request.iter_premise_exists_bool) =
  let name = entry.Helper_registry.name in
  let origin = entry.request.Request.origin in
  let capture_sorts =
    prem.captures |> List.map (fun capture -> sort_ref capture.Request.sort)
  in
  let formal_captures =
    prem.captures |> List.map (fun capture -> Var capture.Request.formal_var)
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
      Condition_schedule.schedule_eq_conditions
        (prem.helper_head_var
         :: List.map (fun capture -> capture.Request.formal_var) prem.captures)
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
  ]
  @ variable_declarations statement
      ([ prem.helper_head_var, sort_ref prem.source_element_sort
       ; prem.source_tail_var, sort_ref spectec_terminals
       ] @ capture_variables prem.captures)
  @ [ statement (eq (helper_on (Const "eps")) (Const "false"))
    ; statement (ceq (helper_on head) (Const "true") body_conditions)
    ; statement (ceq recursive_lhs (Const "true") body_conditions)
    ; statement
        (ceq
           recursive_lhs
           (Const "true")
           [ BoolCond recursive_rhs ])
    ]

let materialize_iter_premise_exists_rule entry (prem : Request.iter_premise_exists_rule) =
  let name = entry.Helper_registry.name in
  let origin = entry.request.Request.origin in
  let result_sort = sort ("IterPremiseRule" ^ Naming.sort_token name ^ "Conf") in
  let ok = Naming.helper_companion ~role:"premise-exists-ok" name in
  let capture_sorts = List.map (fun capture -> sort_ref capture.Request.sort) prem.captures in
  let formal_captures = List.map (fun capture -> Var capture.Request.formal_var) prem.captures in
  let helper_on source = app name (source :: formal_captures) in
  let head = Var prem.helper_head_var in
  let tail = Var prem.source_tail_var in
  let body_conditions = prem.body_conditions in
  let recursive_lhs = helper_on (concat head tail) in
  let recursive_guard = EqCondition (not_eps prem.source_tail_var) in
  let statement node = generated name origin node in
  [ statement (sort_decl result_sort)
  ; statement
      (op name
         (sort_ref spectec_terminals :: capture_sorts)
         result_sort
         ~attrs:[ Frozen (List.init (1 + List.length capture_sorts) (( + ) 1)) ])
  ; statement (op ok [] result_sort ~attrs:[ Ctor ])
  ]
  @ variable_declarations statement
      ([ prem.helper_head_var, sort_ref prem.source_element_sort
       ; prem.source_tail_var, sort_ref spectec_terminals
       ] @ capture_variables prem.captures)
  @ [ statement (crl (helper_on head) (Const ok) body_conditions)
    ; statement
        (crl recursive_lhs (Const ok) (recursive_guard :: body_conditions))
    ; statement
        (crl
           recursive_lhs
           (Const ok)
           [ recursive_guard; RewriteCond (helper_on tail, Const ok) ])
    ]

let materialize_iter_premise_zip_bool entry (prem : Request.iter_premise_zip_bool) =
  let name = entry.Helper_registry.name in
  let origin = entry.request.Request.origin in
  let capture_sorts =
    prem.captures |> List.map (fun capture -> sort_ref capture.Request.sort)
  in
  let formal_captures =
    prem.captures |> List.map (fun capture -> Var capture.Request.formal_var)
  in
  let helper_on sources =
    app name (sources @ formal_captures)
  in
  let heads =
    prem.sources
    |> List.map (fun (source : Request.iter_zip_source) -> Var source.helper_head_var)
  in
  let tails =
    prem.sources
    |> List.map (fun (source : Request.iter_zip_source) -> Var source.source_tail_var)
  in
  let source_heads =
    List.map2
      (fun (source : Request.iter_zip_source) head ->
        source_item_term source.source_item_shape head)
      prem.sources
      heads
  in
  let recursive_sources = List.map2 concat source_heads tails in
  let body_conditions =
    match
      Condition_schedule.schedule_eq_conditions
        ((prem.sources
          |> List.map (fun (source : Request.iter_zip_source) -> source.helper_head_var))
         @ List.map (fun capture -> capture.Request.formal_var) prem.captures)
        prem.body_eq_conditions
    with
    | Some conditions -> conditions
    | None -> prem.body_eq_conditions
  in
  let recursive_conditions =
    (prem.sources
     |> List.map (fun (source : Request.iter_zip_source) -> not_eps source.source_tail_var))
    @ body_conditions
  in
  let statement node = generated name origin node in
  [ statement
      (op name
         ((prem.sources |> List.map (fun _ -> sort_ref spectec_terminals))
          @ capture_sorts)
         (sort "Bool"))
  ]
  @ variable_declarations statement
      (source_variables prem.sources @ capture_variables prem.captures)
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

let materialize_iter_premise_zip_rule entry (prem : Request.iter_premise_zip_rule) =
  let name = entry.Helper_registry.name in
  let origin = entry.request.Request.origin in
  let result_sort = sort ("IterPremiseRule" ^ Naming.sort_token name ^ "Conf") in
  let ok = Naming.helper_companion ~role:"premise-zip-ok" name in
  let capture_sorts = List.map (fun capture -> sort_ref capture.Request.sort) prem.captures in
  let formal_captures = List.map (fun capture -> Var capture.Request.formal_var) prem.captures in
  let helper_on sources = app name (sources @ formal_captures) in
  let heads =
    List.map
      (fun (source : Request.iter_zip_source) -> Var source.helper_head_var)
      prem.sources
  in
  let tails =
    List.map
      (fun (source : Request.iter_zip_source) -> Var source.source_tail_var)
      prem.sources
  in
  let source_heads =
    List.map2
      (fun (source : Request.iter_zip_source) head ->
        source_item_term source.source_item_shape head)
      prem.sources heads
  in
  let recursive_sources = List.map2 concat source_heads tails in
  let conditions = prem.body_conditions @ [ RewriteCond (helper_on tails, Const ok) ] in
  let statement node = generated name origin node in
  [ statement (sort_decl result_sort)
  ; statement
      (op name
         ((List.map (fun _ -> sort_ref spectec_terminals) prem.sources)
          @ capture_sorts)
         result_sort
         ~attrs:
           [ Frozen
               (List.init
                  (List.length prem.sources + List.length capture_sorts)
                  (( + ) 1)) ])
  ; statement (op ok [] result_sort ~attrs:[ Ctor ])
  ]
  @ variable_declarations statement
      (source_variables prem.sources @ capture_variables prem.captures)
  @ [ statement
        (rl
           (helper_on (List.map (fun _ -> Const "eps") prem.sources))
           (Const ok))
    ; statement (crl (helper_on recursive_sources) (Const ok) conditions)
    ]

let materialize_iter_pattern_zip entry (pattern : Request.iter_pattern_zip) =
  let name = entry.Helper_registry.name in
  let origin = entry.request.Request.origin in
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
    |> List.map (fun (source : Request.iter_pattern_zip_source) ->
      source_item_term source.source_item_shape source.source_head_term)
  in
  let source_tails =
    pattern.sources
    |> List.map (fun (source : Request.iter_pattern_zip_source) -> Var source.source_tail_var)
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
    match
      Condition_schedule.schedule_eq_conditions
        initial_bound pattern.body_eq_conditions
    with
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
  ]
  @ variable_declarations statement
      ((pattern.subject_tail_var, sort_ref spectec_terminals)
       :: (pattern.sources
           |> List.map (fun (source : Request.iter_pattern_zip_source) ->
             source.source_tail_var, sort_ref spectec_terminals)))
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
