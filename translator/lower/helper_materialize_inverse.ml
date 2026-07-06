open Maude_ir
open Helper_request
open Helper_materialize_support

let concatn_chunks_result_op name = "concatnChunks" ^ name
let concatn_chunks_fail_op name = "concatnChunks" ^ name ^ "Fail"
let concatn_chunks_inverse_op name = name ^ "Inverse"
let concatn_chunks_prepend_op name = name ^ "Prepend"
let fixed_concat_result_op name = "fixedConcat" ^ name
let fixed_concat_inverse_op name = name ^ "FixedInverse"

let concatn_chunks_sort name =
  sort ("ConcatnChunks" ^ name)

let fixed_concat_sort name =
  sort ("FixedConcat" ^ name)

let fixed_concat2_match_condition name ~type_witness ~known ~left ~right =
  MatchCond
    ( app (fixed_concat_result_op name) [ left; right ]
    , app (fixed_concat_inverse_op name) [ type_witness; known ] )

let materialize_fixed_inverse_concat2 entry (_inverse : fixed_inverse_concat2) =
  let name = entry.Helper_registry.name in
  let origin = entry.request.origin in
  let result_name = fixed_concat_result_op name in
  let inverse_name = fixed_concat_inverse_op name in
  let result_sort = fixed_concat_sort name in
  let typ = Var "FIC_T" in
  let x = Var "FIC_X" in
  let y = Var "FIC_Y" in
  let xs = Var "FIC_XS" in
  let xs1 = Var "FIC_XS1" in
  let xs2 = Var "FIC_XS2" in
  let statement node = generated name origin node in
  [ statement (sort_decl result_sort)
  ; statement
      (op result_name
         [ sort_ref spectec_terminals; sort_ref spectec_terminals ]
         result_sort
         ~attrs:[ Ctor ])
  ; statement
      (op inverse_name
         [ sort_ref spectec_type; sort_ref spectec_terminals ]
         result_sort)
  ; statement (var "FIC_T" (sort_ref spectec_type))
  ; statement (var "FIC_X" (sort_ref spectec_terminal))
  ; statement (var "FIC_Y" (sort_ref spectec_terminal))
  ; statement (var "FIC_XS" (sort_ref spectec_terminals))
  ; statement (var "FIC_XS1" (sort_ref spectec_terminals))
  ; statement (var "FIC_XS2" (sort_ref spectec_terminals))
  ; statement
      (eq
         (app inverse_name [ typ; Const "eps" ])
         (app result_name [ Const "eps"; Const "eps" ]))
  ; statement
      (ceq
         (app inverse_name [ typ; concat x (concat y xs) ])
         (app result_name [ concat x xs1; concat y xs2 ])
         [ MatchCond
             ( app result_name [ xs1; xs2 ]
             , app inverse_name [ typ; xs ] )
         ])
  ]

let materialize_inverse_concatn_chunks entry (inverse : inverse_concatn_chunks) =
  let name = entry.Helper_registry.name in
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
  let helper source width count =
    app inverse_name (capture_vars @ [ source; width; count ])
  in
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
     |> List.map (fun capture ->
       statement (var capture.formal_var (sort_ref capture.sort))))
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
  let name = entry.Helper_registry.name in
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
