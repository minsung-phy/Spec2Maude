open Builtin_types

let render_maude_interface ?(output_load = "output") entries =
  let has_entry source_id =
    List.exists (fun entry -> entry.source_id = source_id) entries
  in
  let has_bits =
    has_entry "ibits_" || has_entry "inv_ibits_"
  in
  let has_bytes =
    has_entry "ibytes_" || has_entry "inv_ibytes_"
  in
  let has_integer_conversion =
    has_entry "wrap__" || has_entry "extend__"
  in
  let has_integer_bit_count =
    has_entry "iclz_" || has_entry "ictz_" || has_entry "ipopcnt_"
  in
  let has_integer_bitwise =
    has_entry "inot_" || has_entry "irev_" || has_entry "iand_"
    || has_entry "iandnot_" || has_entry "ior_" || has_entry "ixor_"
    || has_entry "ibitselect_"
  in
  let has_integer_shift_rotate =
    has_entry "ishl_" || has_entry "ishr_" || has_entry "irotl_"
    || has_entry "irotr_"
  in
  let has_integer_narrow =
    has_entry "narrow__"
  in
  let has_integer_average =
    has_entry "iavgr_"
  in
  let has_integer_q15 =
    has_entry "iq15mulr_sat_"
  in
  let has_rational_integer =
    has_entry "truncz" || has_entry "ceilz"
  in
  let has_float_sign =
    has_entry "fabs_" || has_entry "fneg_" || has_entry "fcopysign_"
  in
  let has_float_to_int =
    has_entry "trunc__" || has_entry "trunc_sat__"
  in
  let has_float_compare =
    has_entry "feq_" || has_entry "fne_" || has_entry "flt_"
    || has_entry "fgt_" || has_entry "fle_" || has_entry "fge_"
  in
  let has_float_minmax =
    has_entry "fmin_" || has_entry "fmax_" || has_entry "fpmin_"
    || has_entry "fpmax_"
  in
  let has_float_round =
    has_entry "fceil_" || has_entry "ffloor_" || has_entry "ftrunc_"
    || has_entry "fnearest_"
  in
  let has_float_sqrt =
    has_entry "fsqrt_"
  in
  let has_float_arith =
    has_entry "fadd_" || has_entry "fsub_" || has_entry "fmul_"
    || has_entry "fdiv_"
  in
  let has_float_promote = has_entry "promote__" in
  let has_float_demote = has_entry "demote__" in
  let has_float_exact =
    has_float_to_int || has_float_compare || has_float_minmax
    || has_float_round || has_float_sqrt || has_float_arith || has_float_promote
    || has_float_demote
  in
  let has_lanes =
    has_entry "lanes_" || has_entry "inv_lanes_"
  in
  let has_float_rep =
    has_entry "fbits_" || has_entry "inv_fbits_"
    || has_entry "fbytes_" || has_entry "inv_fbytes_"
    || has_lanes
  in
  let has_num_bytes =
    has_entry "nbytes_" || has_entry "inv_nbytes_"
  in
  let has_storage_const_bytes =
    has_entry "zbytes_" || has_entry "cbytes_"
    || has_entry "inv_zbytes_" || has_entry "inv_cbytes_"
  in
  let helper_decls =
    Builtin_int_semantics.helper_decls
      ~has_bits
      ~has_bytes
      ~has_integer_conversion
      ~has_integer_bit_count
      ~has_integer_bitwise
      ~has_integer_shift_rotate
      ~has_integer_narrow
      ~has_integer_average
      ~has_integer_q15
      ~has_rational_integer
    @ Builtin_float_semantics.helper_decls
        ~has_float_sign
        ~has_float_rep
        ~has_float_exact
    @ Builtin_vector_semantics.helper_decls
        ~has_float_rep
        ~has_num_bytes
        ~has_storage_const_bytes
        ~has_lanes
  in
  let implemented_equations =
    Builtin_vector_semantics.implemented_equations ~has_entry
    @ Builtin_int_semantics.implemented_equations ~has_entry
    @ Builtin_float_semantics.implemented_equations ~has_entry
  in
  let obligation_comments =
    entries
    |> List.map (fun entry ->
      Printf.sprintf "  --- %s: %s -> %s (%s)"
        (status_to_string entry.status)
        entry.source_id
        entry.generated_op_stem
        entry.hint_location)
  in
  String.concat "\n"
    ([ "--- Spec2Maude builtin backend interface."
     ; "--- This module intentionally contains no fake default equations."
     ; "--- Implement a builtin here only after its WebAssembly semantics is fixed."
     ; "load " ^ output_load
     ; ""
     ; "mod WASM-BUILTINS is"
     ; "  inc SPEC2MAUDE-GENERATED ."
     ; ""
     ; Printf.sprintf "  --- hint(builtin) registry: %d total, %d implemented, %d obligations."
         (count entries)
         (implemented_count entries)
         (obligation_count entries)
     ]
     @ obligation_comments
     @ helper_decls
     @ implemented_equations
     @ [ ""
       ; "endm"
       ; ""
       ])
