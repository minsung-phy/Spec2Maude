open Maude_ir
module Request = Helper_request
open Helper_emission

let decode_chunks_result_op = Naming.helper_companion ~role:"decode-chunks-result"
let decode_chunks_op = Naming.helper_companion ~role:"decode-chunks"
let decode_chunks_prepend_op = Naming.helper_companion ~role:"decode-chunks-prepend"
let unzip2_result_op = Naming.helper_companion ~role:"unzip2-result"
let unzip2_op = Naming.helper_companion ~role:"unzip2"

let decode_chunks_sort name =
  sort ("DecodeChunks" ^ Naming.sort_token name)

let unzip2_sort name =
  sort ("Unzip2" ^ Naming.sort_token name)

let unzip2_result_constructor name origin =
  generated name origin
    (op (unzip2_result_op name)
       [ sort_ref spectec_terminals; sort_ref spectec_terminals ]
       (unzip2_sort name)
       ~attrs:[ Ctor ])

let decode_chunks_result_constructor name origin =
  generated name origin
    (op (decode_chunks_result_op name)
       [ sort_ref spectec_terminals ]
       (decode_chunks_sort name)
       ~attrs:[ Ctor ])

let unzip2_match_condition name ~chunks ~left ~right =
  MatchCond
    ( app (unzip2_result_op name) [ left; right ]
    , app (unzip2_op name) [ chunks ] )

let materialize_unzip2 entry (_request : Request.unzip2) =
  let name = entry.Helper_registry.name in
  let origin = entry.request.Request.origin in
  let result_name = unzip2_result_op name in
  let unzip_name = unzip2_op name in
  let result_sort = unzip2_sort name in
  let x, names =
    Local_name.fresh_qualified
      Local_name.empty Local_name.Head (sort_ref spectec_terminal)
  in
  let y, names =
    Local_name.fresh_qualified
      names Local_name.Head (sort_ref spectec_terminal)
  in
  let chunks, names =
    Local_name.fresh_qualified
      names Local_name.Stream (sort_ref spectec_terminals)
  in
  let xs1, names =
    Local_name.fresh_qualified
      names Local_name.Stream (sort_ref spectec_terminals)
  in
  let xs2, _ =
    Local_name.fresh_qualified
      names Local_name.Stream (sort_ref spectec_terminals)
  in
  let statement node = generated name origin node in
  [ statement (sort_decl result_sort)
  ; unzip2_result_constructor name origin
  ; statement
      (op unzip_name
         [ sort_ref spectec_terminals ]
         result_sort)
  ; statement
      (eq
         (app unzip_name [ Const "eps" ])
         (app result_name [ Const "eps"; Const "eps" ]))
  ; statement
      (ceq
         (app unzip_name [ concat (app "seq" [ concat x y ]) chunks ])
         (app result_name [ concat x xs1; concat y xs2 ])
         [ MatchCond
             ( app result_name [ xs1; xs2 ]
             , app unzip_name [ chunks ] )
         ])
  ]

let materialize_decode_chunks entry (request : Request.decode_chunks) =
  let name = entry.Helper_registry.name in
  let origin = entry.request.Request.origin in
  let result_name = decode_chunks_result_op name in
  let decode_name = decode_chunks_op name in
  let prepend_name = decode_chunks_prepend_op name in
  let result_sort = decode_chunks_sort name in
  let target_head = Var request.target_head_var in
  let target_stream = Var request.target_stream_var in
  let chunks_tail = Var request.chunks_tail_var in
  let chunk = Var request.chunk_var in
  let capture_vars =
    request.captures |> List.map (fun capture -> Var capture.Request.formal_var)
  in
  let helper source =
    app decode_name (capture_vars @ [ source ])
  in
  let result stream = app result_name [ stream ] in
  let prepend head tail = app prepend_name [ head; tail ] in
  let source_nonempty = concat (app "seq" [ chunk ]) chunks_tail in
  let inverse_call = app request.inverse_op request.inverse_call_formals in
  let original_call = app request.bytes_op request.bytes_call_formals in
  let statement node = generated name origin node in
  [ statement (sort_decl result_sort)
  ; decode_chunks_result_constructor name origin
  ; statement
      (op decode_name
         ((request.captures |> List.map (fun capture -> sort_ref capture.Request.sort))
          @ [ sort_ref spectec_terminals ])
         result_sort)
  ; statement
      (op prepend_name
         [ sort_ref spectec_terminal; sort_ref result_sort ]
         result_sort)
  ]
  @ variable_declarations statement
      ((request.captures
        |> List.map (fun capture -> capture.Request.formal_var, sort_ref capture.Request.sort))
       @ [ request.target_head_var, sort_ref spectec_terminal
         ; request.target_stream_var, sort_ref spectec_terminals
         ; request.chunks_tail_var, sort_ref spectec_terminals
         ; request.chunk_var, sort_ref spectec_terminals
         ])
  @ [ statement
        (eq
           (helper (Const "eps"))
           (result (Const "eps")))
    ; statement
        (ceq
           (helper source_nonempty)
           (prepend target_head (helper chunks_tail))
           [ MatchCond (target_head, inverse_call)
           ; EqCond (original_call, chunk)
           ])
    ; statement
        (eq
           (prepend target_head (result target_stream))
           (result (concat target_head target_stream)))
    ]

let materialize_optional_map_inverse entry (inverse : Request.optional_map_inverse) =
  let name = entry.Helper_registry.name in
  let origin = entry.request.Request.origin in
  let capture_sorts =
    inverse.captures |> List.map (fun capture -> sort_ref capture.Request.sort)
  in
  let formal_captures =
    inverse.captures |> List.map (fun capture -> Var capture.Request.formal_var)
  in
  let helper_on term =
    app name (term :: formal_captures)
  in
  let head = Var inverse.helper_head_var in
  let result_conditions =
    match
      Condition_schedule.schedule_eq_conditions
        (inverse.helper_head_var
         :: List.map (fun capture -> capture.Request.formal_var) inverse.captures)
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
  ]
  @ variable_declarations statement
      ((inverse.helper_head_var, sort_ref inverse.source_element_sort)
       :: (inverse.captures
           |> List.map (fun capture ->
             capture.Request.formal_var, sort_ref capture.Request.sort)))
  @ [ statement (eq (helper_on (Const "eps")) (Const "eps"))
    ; statement (ceq (helper_on inverse.lowered_body) head result_conditions)
    ]
