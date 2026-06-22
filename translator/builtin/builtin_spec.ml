open Builtin_types

let implemented_source_ids =
  [ "ibits_"
  ; "fbits_"
  ; "ibytes_"
  ; "fbytes_"
  ; "nbytes_"
  ; "inv_ibits_"
  ; "inv_fbits_"
  ; "inv_ibytes_"
  ; "inv_fbytes_"
  ; "inv_nbytes_"
  ; "vbytes_"
  ; "inv_vbytes_"
  ; "wrap__"
  ; "extend__"
  ; "iclz_"
  ; "ictz_"
  ; "ipopcnt_"
  ; "inot_"
  ; "irev_"
  ; "iand_"
  ; "iandnot_"
  ; "ior_"
  ; "ixor_"
  ; "ishl_"
  ; "ishr_"
  ; "irotl_"
  ; "irotr_"
  ; "ibitselect_"
  ; "iavgr_"
  ; "iq15mulr_sat_"
  ; "fabs_"
  ; "fneg_"
  ; "fsqrt_"
  ; "fcopysign_"
  ; "fmin_"
  ; "fmax_"
  ; "fpmin_"
  ; "fpmax_"
  ; "fceil_"
  ; "ffloor_"
  ; "ftrunc_"
  ; "fnearest_"
  ; "fadd_"
  ; "fsub_"
  ; "fmul_"
  ; "fdiv_"
  ; "feq_"
  ; "fne_"
  ; "flt_"
  ; "fgt_"
  ; "fle_"
  ; "fge_"
  ; "narrow__"
  ; "reinterpret__"
  ; "zbytes_"
  ; "cbytes_"
  ; "inv_zbytes_"
  ; "inv_cbytes_"
  ; "lanes_"
  ; "inv_lanes_"
  ; "trunc__"
  ; "trunc_sat__"
  ; "promote__"
  ; "demote__"
  ; "convert__"
  ; "truncz"
  ; "ceilz"
  ]

let is_implemented_source_id source_id =
  List.exists (( = ) source_id) implemented_source_ids

let smoke_test_for_source_id = function
  | "ibits_" -> Some "red in WASM-BUILTINS : defibitsx5fx(4, iN.wrap_(5)) ."
  | "ibytes_" -> Some "red in WASM-BUILTINS : defibytesx5fx(16, iN.wrap_(4660)) ."
  | "vbytes_" -> Some "red in WASM-BUILTINS : defvbytesx5fx(vectype.v128, vecx5f.wrap_(4660)) ."
  | "fbits_" ->
    Some "red in WASM-BUILTINS : deffbitsx5fx(32, fN.pos_(fNmag.norm__(0, 0))) ."
  | "inv_ibits_" -> Some "red in WASM-BUILTINS : definvx5fxibitsx5fx(4, 0 1 0 1) ."
  | "inv_fbits_" ->
    Some
      "red in WASM-BUILTINS : definvx5fxfbitsx5fx(32, 0 0 1 1 1 1 1 1 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0) ."
  | "inv_ibytes_" -> Some "red in WASM-BUILTINS : definvx5fxibytesx5fx(16, 52 18) ."
  | "fbytes_" ->
    Some "red in WASM-BUILTINS : deffbytesx5fx(32, fN.pos_(fNmag.norm__(0, 0))) ."
  | "nbytes_" ->
    Some "red in WASM-BUILTINS : defnbytesx5fx(numtype.f32, numx5f.wrap_(fN.pos_(fNmag.norm__(0, 0)))) ."
  | "inv_fbytes_" ->
    Some "red in WASM-BUILTINS : definvx5fxfbytesx5fx(32, 0 0 128 63) ."
  | "inv_nbytes_" ->
    Some "red in WASM-BUILTINS : definvx5fxnbytesx5fx(numtype.f32, 0 0 128 63) ."
  | "inv_vbytes_" ->
    Some
      "red in WASM-BUILTINS : definvx5fxvbytesx5fx(vectype.v128, 52 18 0 0 0 0 0 0 0 0 0 0 0 0 0 0) ."
  | "wrap__" -> Some "red in WASM-BUILTINS : defwrapx5fxx5fx(8, 4, iN.wrap_(255)) ."
  | "extend__" -> Some "red in WASM-BUILTINS : defextendx5fxx5fx(4, 8, sx.s, iN.wrap_(15)) ."
  | "iclz_" -> Some "red in WASM-BUILTINS : deficlzx5fx(4, iN.wrap_(1)) ."
  | "ictz_" -> Some "red in WASM-BUILTINS : defictzx5fx(4, iN.wrap_(8)) ."
  | "ipopcnt_" -> Some "red in WASM-BUILTINS : defipopcntx5fx(4, iN.wrap_(13)) ."
  | "inot_" -> Some "red in WASM-BUILTINS : definotx5fx(4, iN.wrap_(5)) ."
  | "irev_" -> Some "red in WASM-BUILTINS : defirevx5fx(4, iN.wrap_(2)) ."
  | "iand_" -> Some "red in WASM-BUILTINS : defiandx5fx(4, iN.wrap_(12), iN.wrap_(10)) ."
  | "iandnot_" -> Some "red in WASM-BUILTINS : defiandnotx5fx(4, iN.wrap_(12), iN.wrap_(10)) ."
  | "ior_" -> Some "red in WASM-BUILTINS : defiorx5fx(4, iN.wrap_(12), iN.wrap_(10)) ."
  | "ixor_" -> Some "red in WASM-BUILTINS : defixorx5fx(4, iN.wrap_(12), iN.wrap_(10)) ."
  | "ishl_" -> Some "red in WASM-BUILTINS : defishlx5fx(4, iN.wrap_(3), u32.wrap_(1)) ."
  | "ishr_" -> Some "red in WASM-BUILTINS : defishrx5fx(4, sx.s, iN.wrap_(8), u32.wrap_(1)) ."
  | "irotl_" -> Some "red in WASM-BUILTINS : defirotlx5fx(4, iN.wrap_(9), iN.wrap_(1)) ."
  | "irotr_" -> Some "red in WASM-BUILTINS : defirotrx5fx(4, iN.wrap_(9), iN.wrap_(1)) ."
  | "ibitselect_" -> Some "red in WASM-BUILTINS : defibitselectx5fx(4, iN.wrap_(12), iN.wrap_(3), iN.wrap_(10)) ."
  | "iavgr_" -> Some "red in WASM-BUILTINS : defiavgrx5fx(8, sx.u, iN.wrap_(254), iN.wrap_(255)) ."
  | "iq15mulr_sat_" ->
    Some "red in WASM-BUILTINS : defiq15mulrx5fxsatx5fx(16, sx.s, iN.wrap_(32768), iN.wrap_(32768)) ."
  | "fabs_" -> Some "red in WASM-BUILTINS : deffabsx5fx(32, fN.neg_(fNmag.norm__(1, 0))) ."
  | "fneg_" -> Some "red in WASM-BUILTINS : deffnegx5fx(32, fN.pos_(fNmag.inf)) ."
  | "fsqrt_" ->
    Some
      "red in WASM-BUILTINS : deffsqrtx5fx(32, fN.pos_(fNmag.norm__(0, 2))) ."
  | "fcopysign_" ->
    Some "red in WASM-BUILTINS : deffcopysignx5fx(32, fN.pos_(fNmag.inf), fN.neg_(fNmag.subnorm_(0))) ."
  | "fmin_" ->
    Some
      "red in WASM-BUILTINS : deffminx5fx(32, fN.pos_(fNmag.subnorm_(0)), fN.neg_(fNmag.subnorm_(0))) ."
  | "fmax_" ->
    Some
      "red in WASM-BUILTINS : deffmaxx5fx(32, fN.pos_(fNmag.subnorm_(0)), fN.neg_(fNmag.subnorm_(0))) ."
  | "fpmin_" ->
    Some
      "red in WASM-BUILTINS : deffpminx5fx(32, fN.pos_(fNmag.norm__(2, 0)), fN.pos_(fNmag.norm__(1, 0))) ."
  | "fpmax_" ->
    Some
      "red in WASM-BUILTINS : deffpmaxx5fx(32, fN.pos_(fNmag.norm__(1, 0)), fN.pos_(fNmag.norm__(2, 0))) ."
  | "fceil_" ->
    Some
      "red in WASM-BUILTINS : deffceilx5fx(32, fN.neg_(fNmag.norm__(0, -1))) ."
  | "ffloor_" ->
    Some
      "red in WASM-BUILTINS : defffloorx5fx(32, fN.pos_(fNmag.norm__(0, -1))) ."
  | "ftrunc_" ->
    Some
      "red in WASM-BUILTINS : defftruncx5fx(32, fN.neg_(fNmag.norm__(0, -1))) ."
  | "fnearest_" ->
    Some
      "red in WASM-BUILTINS : deffnearestx5fx(32, fN.pos_(fNmag.norm__(0, -1))) ."
  | "fadd_" ->
    Some
      "red in WASM-BUILTINS : deffaddx5fx(32, fN.pos_(fNmag.norm__(0, 0)), fN.pos_(fNmag.norm__(0, 0))) ."
  | "fsub_" ->
    Some
      "red in WASM-BUILTINS : deffsubx5fx(32, fN.pos_(fNmag.norm__(0, 0)), fN.pos_(fNmag.norm__(0, 0))) ."
  | "fmul_" ->
    Some
      "red in WASM-BUILTINS : deffmulx5fx(32, fN.pos_(fNmag.norm__(0, 1)), fN.pos_(fNmag.norm__(0, 1))) ."
  | "fdiv_" ->
    Some
      "red in WASM-BUILTINS : deffdivx5fx(32, fN.pos_(fNmag.norm__(0, 0)), fN.pos_(fNmag.norm__(0, 1))) ."
  | "feq_" ->
    Some
      "red in WASM-BUILTINS : deffeqx5fx(32, fN.pos_(fNmag.subnorm_(0)), fN.neg_(fNmag.subnorm_(0))) ."
  | "fne_" ->
    Some
      "red in WASM-BUILTINS : deffnex5fx(32, fN.pos_(fNmag.nan_(1)), fN.pos_(fNmag.norm__(0, 0))) ."
  | "flt_" ->
    Some
      "red in WASM-BUILTINS : deffltx5fx(32, fN.neg_(fNmag.inf), fN.neg_(fNmag.norm__(0, 0))) ."
  | "fgt_" ->
    Some
      "red in WASM-BUILTINS : deffgtx5fx(32, fN.pos_(fNmag.inf), fN.pos_(fNmag.norm__(0, 0))) ."
  | "fle_" ->
    Some
      "red in WASM-BUILTINS : defflex5fx(32, fN.pos_(fNmag.norm__(0, 0)), fN.pos_(fNmag.norm__(0, 0))) ."
  | "fge_" ->
    Some
      "red in WASM-BUILTINS : deffgex5fx(32, fN.pos_(fNmag.nan_(1)), fN.pos_(fNmag.norm__(0, 0))) ."
  | "narrow__" -> Some "red in WASM-BUILTINS : defnarrowx5fxx5fx(16, 8, sx.s, iN.wrap_(65535)) ."
  | "reinterpret__" ->
    Some
      "red in WASM-BUILTINS : defreinterpretx5fxx5fx(numtype.i32, numtype.f32, numx5f.wrap_(1065353216)) ."
  | "zbytes_" ->
    Some "red in WASM-BUILTINS : defzbytesx5fx(packtype.i16, packx5f.wrap_(4660)) ."
  | "cbytes_" ->
    Some "red in WASM-BUILTINS : defcbytesx5fx(numtype.f32, numx5f.wrap_(fN.pos_(fNmag.norm__(0, 0)))) ."
  | "inv_zbytes_" ->
    Some "red in WASM-BUILTINS : definvx5fxzbytesx5fx(packtype.i16, 52 18) ."
  | "inv_cbytes_" ->
    Some "red in WASM-BUILTINS : definvx5fxcbytesx5fx(numtype.f32, 0 0 128 63) ."
  | "lanes_" ->
    Some "red in WASM-BUILTINS : deflanesx5fx(shape._x_(numtype.i32, dim.wrap_(4)), vecx5f.wrap_(67305985)) ."
  | "inv_lanes_" ->
    Some
      "red in WASM-BUILTINS : definvx5fxlanesx5fx(shape._x_(packtype.i8, dim.wrap_(16)), iN.wrap_(1) iN.wrap_(2) iN.wrap_(3) iN.wrap_(4) iN.wrap_(0) iN.wrap_(0) iN.wrap_(0) iN.wrap_(0) iN.wrap_(0) iN.wrap_(0) iN.wrap_(0) iN.wrap_(0) iN.wrap_(0) iN.wrap_(0) iN.wrap_(0) iN.wrap_(0)) ."
  | "trunc__" ->
    Some
      "red in WASM-BUILTINS : deftruncx5fxx5fx(32, 8, sx.u, fN.pos_(fNmag.norm__(0, 0))) ."
  | "trunc_sat__" ->
    Some
      "red in WASM-BUILTINS : deftruncx5fxsatx5fxx5fx(32, 8, sx.u, fN.neg_(fNmag.norm__(0, 0))) ."
  | "promote__" ->
    Some
      "red in WASM-BUILTINS : defpromotex5fxx5fx(32, 64, fN.neg_(fNmag.subnorm_(1))) ."
  | "demote__" ->
    Some
      "red in WASM-BUILTINS : defdemotex5fxx5fx(64, 32, fN.pos_(fNmag.norm__(0, 128))) ."
  | "convert__" ->
    Some
      "red in WASM-BUILTINS : defconvertx5fxx5fx(64, 32, sx.u, iN.wrap_(16777217)) ."
  | "truncz" -> Some "red in WASM-BUILTINS : deftruncz(rat(-3/2)) ."
  | "ceilz" -> Some "red in WASM-BUILTINS : defceilz(rat(-3/2)) ."
  | _ -> None


let semantics_source_for_source_id = function
  | "ibits_" | "inv_ibits_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec representation declarations and integer count comments; bit sequence is MSB-first"
  | "ibytes_" | "inv_ibytes_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec representation declarations and WebAssembly little-endian byte representation"
  | "fbits_" | "inv_fbits_" ->
    "wasm-3.0/1.1-syntax.values.spectec fN/fNmag IEEE field structure plus wasm-3.0/3.1-numerics.scalar.spectec representation declarations; bit sequence is MSB-first over sign/exponent/fraction fields"
  | "fbytes_" | "inv_fbytes_" ->
    "wasm-3.0/1.1-syntax.values.spectec fN/fNmag IEEE field structure plus WebAssembly little-endian byte representation of the same sign/exponent/fraction bit pattern"
  | "vbytes_" | "inv_vbytes_" ->
    "wasm-3.0/1.1-syntax.values.spectec and 1.3-syntax.instructions.spectec aliases: vec_(V128) is vN(128), vN(N) is uN(N); bytes are the same little-endian 128-bit integer bytes as $ibytes_/$inv_ibytes_"
  | "wrap__" ->
    "wasm-3.0/3.1-numerics.scalar.spectec conversion declaration; integer wrap is modulo target width"
  | "extend__" ->
    "wasm-3.0/3.1-numerics.scalar.spectec conversion declaration plus $iextend_ equations for unsigned/signed extension"
  | "iclz_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec builtin comment: count leading zeros in $ibits_"
  | "ictz_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec builtin comment: count trailing zeros in $ibits_"
  | "ipopcnt_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec builtin comment: count one bits in $ibits_"
  | "inot_" | "irev_" | "iand_" | "iandnot_" | "ior_" | "ixor_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec integer bitwise builtin declarations; implemented over the MSB-first $ibits_ representation"
  | "ibitselect_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec integer ternary bit selection; each result bit is selected from the first or second operand by the mask operand"
  | "iavgr_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec AVGR U path plus WebAssembly reference interpreter: unsigned rounded average (i + j + 1) / 2"
  | "iq15mulr_sat_" ->
    "wasm-3.0/3.2-numerics.vector.spectec Q15MULR_SAT S path plus WebAssembly reference interpreter: signed i16 q15 rounded multiply with saturation"
  | "fabs_" | "fneg_" | "fcopysign_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec structural fN sign operation plus WebAssembly reference interpreter bitwise sign semantics; preserves magnitude payload, including infinities and NaNs"
  | "fsqrt_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec floating sqrt declaration plus vendor/wasm/exec/fxx.ml sqrt/unary semantics: NaNs are source-canonicalized, negative non-zero inputs produce the reference default quiet NaN, signed zero and positive infinity are fixed points, and non-negative finite values use exact rational square comparisons to round sqrt to target fN with nearest-even semantics"
  | "fmin_" | "fmax_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec floating min/max declarations plus WebAssembly reference min/max semantics: NaN result is source $canon_-quieted from a NaN operand, min/max preserve the specified signed-zero behavior, and non-NaN values are ordered numerically"
  | "fpmin_" | "fpmax_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec pseudo floating min/max declarations plus WebAssembly reference SIMD pmin/pmax semantics: select the second operand only when the relevant strict less-than comparison is true; otherwise preserve the first operand"
  | "fceil_" | "ffloor_" | "ftrunc_" | "fnearest_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec unary floating rounding declarations plus WebAssembly reference interpreter semantics: infinities are fixed points, NaNs are source $canon_-quieted, finite values are converted exactly to Rat, rounded to an integral value, and re-encoded exactly as fN while preserving signed zero"
  | "fadd_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec floating add declaration plus vendor/wasm/exec/fxx.ml add/binary semantics: NaNs are source-canonicalized, opposite infinities produce the default positive quiet NaN, finite values are added exactly as Rat and rounded to target fN with nearest-even semantics while preserving the -0 + -0 signed-zero case"
  | "fsub_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec floating subtraction declaration plus vendor/wasm/exec/fxx.ml sub/binary semantics: NaNs are source-canonicalized from the original operands; non-NaN subtraction is lowered to addition with a structurally sign-negated second operand, preserving infinity and signed-zero behavior through the fadd_ equations"
  | "fmul_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec floating multiplication declaration plus vendor/wasm/exec/fxx.ml mul/binary semantics: NaNs are source-canonicalized, infinity-times-zero produces the reference default quiet NaN, finite operands are multiplied exactly as Rat and rounded to target fN with nearest-even semantics, and zero/infinity signs follow operand sign xor"
  | "fdiv_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec floating division declaration plus vendor/wasm/exec/fxx.ml div/binary semantics: NaNs are source-canonicalized, zero-divided-by-zero and infinity-divided-by-infinity produce the reference default quiet NaN, finite nonzero divided by zero produces signed infinity, finite divided by infinity produces signed zero, and finite nonzero division is exact Rat division rounded to target fN with nearest-even semantics"
  | "feq_" | "fne_" | "flt_" | "fgt_" | "fle_" | "fge_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec floating comparison declarations plus WebAssembly reference comparison semantics: NaN is unordered, signed zeros compare equal, and finite/infinite non-NaN values compare by numeric value"
  | "ishl_" | "ishr_" | "irotl_" | "irotr_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec integer shift/rotate builtin declarations; implemented with shift count modulo bit width"
  | "narrow__" ->
    "wasm-3.0/3.1-numerics.scalar.spectec conversion declaration; integer vector-narrow lane conversion is saturating by target width and signedness"
  | "reinterpret__" ->
    "wasm-3.0/3.1-numerics.scalar.spectec conversion declaration; bit-preserving reinterpret is implemented as nbytes_ followed by inv_nbytes_ when source and target widths match"
  | "truncz" ->
    "wasm-3.0/3.1-numerics.scalar.spectec rational helper; truncate Rat toward zero using Maude RAT floor/ceiling"
  | "ceilz" ->
    "wasm-3.0/3.1-numerics.scalar.spectec rational helper; ceiling over Rat using Maude RAT ceiling"
  | "nbytes_" | "inv_nbytes_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec representation declarations; composite numtype bytes dispatch exactly to integer or float byte representation by numtype constructor"
  | "zbytes_" | "inv_zbytes_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec representation declarations plus wasm-3.0/1.2-syntax.types.spectec $zsize partial cases: storagetype bytes dispatch exactly to numtype, vectype, or packtype byte representation"
  | "cbytes_" | "inv_cbytes_" ->
    "wasm-3.0/3.1-numerics.scalar.spectec representation declarations plus wasm-3.0/1.2-syntax.types.spectec Cnn = Inn | Fnn | Vnn: const bytes dispatch exactly to numtype or vectype byte representation"
  | "lanes_" | "inv_lanes_" ->
    "wasm-3.0/3.2-numerics.vector.spectec lane declarations plus wasm-3.0/1.3-syntax.instructions.spectec lane_/vec_/shape aliases; vector payload is split/reassembled little-endian from low lane to high lane over the same 128-bit raw representation as vbytes_/inv_vbytes_"
  | "trunc__" ->
    "wasm-3.0/3.1-numerics.scalar.spectec conversion declaration plus wasm-3.0/4.3-execution.instructions.spectec cvtop trap rule: finite fN is converted exactly to Rat, truncated toward zero, and returns eps exactly when NaN/inf/out of target range would trap"
  | "trunc_sat__" ->
    "wasm-3.0/3.1-numerics.scalar.spectec conversion declaration plus WebAssembly reference conversion semantics: finite fN is converted exactly to Rat, truncated toward zero, NaN maps to 0, and out-of-range values saturate to the signed/unsigned target bound"
  | "promote__" ->
    "wasm-3.0/3.1-numerics.scalar.spectec conversion declaration plus vendor/wasm/exec/convert.ml F64_.promote_f32: f32 finite values are exactly promoted to f64, infinities preserve sign, and NaNs preserve sign/payload shifted to f64 while setting the f64 quiet-NaN bit"
  | "demote__" ->
    "wasm-3.0/3.1-numerics.scalar.spectec conversion declaration plus vendor/wasm/exec/convert.ml F32_.demote_f64: f64 finite values round to f32 with nearest-even semantics, infinities preserve sign, and NaNs preserve sign/top payload bits while setting the f32 quiet-NaN bit"
  | "convert__" ->
    "wasm-3.0/3.1-numerics.scalar.spectec conversion declaration plus vendor/wasm/exec/convert.ml integer-to-float conversions: iN payloads are interpreted by signedness and rounded to target fN with round-to-nearest-even"
  | "relaxed_trunc__"
  | "R_fmadd" | "R_fmin" | "R_fmax" | "R_idot" | "R_iq15mulr"
  | "R_trunc_u" | "R_trunc_s" | "R_swizzle" | "R_laneselect"
  | "irelaxed_q15mulr_" | "irelaxed_laneselect_"
  | "frelaxed_min_" | "frelaxed_max_" | "frelaxed_madd_" | "frelaxed_nmadd_"
  | "ND" ->
    "OBLIGATION: relaxed or nondeterministic semantics require an explicit deterministic/set-valued backend policy before equations are added"
  | "inv_concat_" | "inv_concatn_" ->
    "OBLIGATION: inverse sequence concatenation is a search/segmentation relation, not a deterministic default; implement only with an explicit source-preserving helper policy"
  | _ ->
    "source hint plus official WebAssembly specification/reference semantics; exact section required before IMPLEMENTED"


let status_of_source_id source_id =
  if is_implemented_source_id source_id then Implemented else Obligation
