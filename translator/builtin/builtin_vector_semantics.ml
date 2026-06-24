let helper_decls ~has_float_rep ~has_num_bytes ~has_storage_const_bytes ~has_lanes =
    (if has_float_rep then
      [ ""
      ; "  --- Implemented builtin family: IEEE-754 bit/byte representation for fN."
      ; "  vars FB_N FB_I FB_M FB_RAW FB_FRAC FB_EXP FB_SIGN FB_MAGBITS FB_RESULT : Nat ."
      ; "  var FB_EINT : Int ."
      ; "  vars FB_F FB_MAG : SpectecTerminal ."
      ; "  vars FB_BITS FB_BYTES : SpectecTerminals ."
      ; "  op builtin.float-bias : Nat -> Nat ."
      ; "  op builtin.float-max-exp-field : Nat -> Nat ."
      ; "  op builtin.float-exp-field : Nat Nat -> Nat ."
      ; "  op builtin.float-frac-field : Nat Nat -> Nat ."
      ; "  op builtin.float-sign-field : Nat Nat -> Nat ."
      ; "  op builtin.float-mag-from-bits : Nat Nat -> SpectecTerminal ."
      ; "  op builtin.float-from-bits : Nat Nat -> SpectecTerminal ."
      ; "  op builtin.float-mag-to-bits : Nat SpectecTerminal -> Nat ."
      ; "  op builtin.float-to-bits : Nat SpectecTerminal -> Nat ."
      ; "  eq builtin.float-bias(FB_N) = _-_(_^_(2, _-_(defe(FB_N), 1)), 1) ."
      ; "  eq builtin.float-max-exp-field(FB_N) = _-_(_^_(2, defe(FB_N)), 1) ."
      ; "  ceq builtin.float-sign-field(FB_N, FB_I) = _quo_(_rem_(FB_I, _^_(2, FB_N)), _^_(2, _-_(FB_N, 1)))"
      ; "    if _>_(FB_N, 0) ."
      ; "  eq builtin.float-exp-field(FB_N, FB_I) ="
      ; "      _rem_(_quo_(_rem_(FB_I, _^_(2, FB_N)), _^_(2, defm(FB_N))), _^_(2, defe(FB_N))) ."
      ; "  eq builtin.float-frac-field(FB_N, FB_I) ="
      ; "      _rem_(_rem_(FB_I, _^_(2, FB_N)), _^_(2, defm(FB_N))) ."
      ; "  ceq builtin.float-mag-from-bits(FB_N, FB_I) = fNmag.subnorm_(FB_FRAC)"
      ; "    if _<_(FB_I, _^_(2, FB_N))"
      ; "       /\\ FB_EXP := builtin.float-exp-field(FB_N, FB_I)"
      ; "       /\\ FB_FRAC := builtin.float-frac-field(FB_N, FB_I)"
      ; "       /\\ FB_EXP = 0 ."
      ; "  ceq builtin.float-mag-from-bits(FB_N, FB_I) = fNmag.inf"
      ; "    if _<_(FB_I, _^_(2, FB_N))"
      ; "       /\\ FB_EXP := builtin.float-exp-field(FB_N, FB_I)"
      ; "       /\\ FB_FRAC := builtin.float-frac-field(FB_N, FB_I)"
      ; "       /\\ FB_EXP = builtin.float-max-exp-field(FB_N)"
      ; "       /\\ FB_FRAC = 0 ."
      ; "  ceq builtin.float-mag-from-bits(FB_N, FB_I) = fNmag.nan_(FB_FRAC)"
      ; "    if _<_(FB_I, _^_(2, FB_N))"
      ; "       /\\ FB_EXP := builtin.float-exp-field(FB_N, FB_I)"
      ; "       /\\ FB_FRAC := builtin.float-frac-field(FB_N, FB_I)"
      ; "       /\\ FB_EXP = builtin.float-max-exp-field(FB_N)"
      ; "       /\\ _>_(FB_FRAC, 0) ."
      ; "  ceq builtin.float-mag-from-bits(FB_N, FB_I) = fNmag.norm__(FB_FRAC, _-_(FB_EXP, builtin.float-bias(FB_N)))"
      ; "    if _<_(FB_I, _^_(2, FB_N))"
      ; "       /\\ FB_EXP := builtin.float-exp-field(FB_N, FB_I)"
      ; "       /\\ FB_FRAC := builtin.float-frac-field(FB_N, FB_I)"
      ; "       /\\ _>_(FB_EXP, 0)"
      ; "       /\\ _<_(FB_EXP, builtin.float-max-exp-field(FB_N)) ."
      ; "  ceq builtin.float-from-bits(FB_N, FB_I) = fN.pos_(builtin.float-mag-from-bits(FB_N, FB_I))"
      ; "    if _<_(FB_I, _^_(2, FB_N))"
      ; "       /\\ builtin.float-sign-field(FB_N, FB_I) = 0 ."
      ; "  ceq builtin.float-from-bits(FB_N, FB_I) = fN.neg_(builtin.float-mag-from-bits(FB_N, FB_I))"
      ; "    if _<_(FB_I, _^_(2, FB_N))"
      ; "       /\\ builtin.float-sign-field(FB_N, FB_I) = 1 ."
      ; "  ceq builtin.float-mag-to-bits(FB_N, fNmag.subnorm_(FB_M)) = FB_M"
      ; "    if _<_(FB_M, _^_(2, defm(FB_N))) ."
      ; "  eq builtin.float-mag-to-bits(FB_N, fNmag.inf) ="
      ; "      _*_(builtin.float-max-exp-field(FB_N), _^_(2, defm(FB_N))) ."
      ; "  ceq builtin.float-mag-to-bits(FB_N, fNmag.nan_(FB_M)) ="
      ; "      _+_(_*_(builtin.float-max-exp-field(FB_N), _^_(2, defm(FB_N))), FB_M)"
      ; "    if _and_(_<=_(1, FB_M), _<_(FB_M, _^_(2, defm(FB_N)))) = true ."
      ; "  ceq builtin.float-mag-to-bits(FB_N, fNmag.norm__(FB_M, FB_EINT)) ="
      ; "      _+_(_*_(_+_(FB_EINT, builtin.float-bias(FB_N)), _^_(2, defm(FB_N))), FB_M)"
      ; "    if (builtin.fnmag-valid(FB_N, fNmag.norm__(FB_M, FB_EINT))) = true ."
      ; "  ceq builtin.float-to-bits(FB_N, fN.pos_(FB_MAG)) = FB_MAGBITS"
      ; "    if (builtin.fnmag-valid(FB_N, FB_MAG)) = true"
      ; "       /\\ FB_MAGBITS := builtin.float-mag-to-bits(FB_N, FB_MAG) ."
      ; "  ceq builtin.float-to-bits(FB_N, fN.neg_(FB_MAG)) = _+_(_^_(2, _-_(FB_N, 1)), FB_MAGBITS)"
      ; "    if (builtin.fnmag-valid(FB_N, FB_MAG)) = true"
      ; "       /\\ FB_MAGBITS := builtin.float-mag-to-bits(FB_N, FB_MAG) ."
      ]
    else
      [])
    @
    (if has_num_bytes then
      [ ""
      ; "  --- Implemented builtin family: composite numtype bytes."
      ; "  vars NB_N NB_I NB_RAW : Nat ."
      ; "  var NB_PAYLOAD : SpectecTerminal ."
      ; "  var NB_BYTES : SpectecTerminals ."
      ; "  op builtin.nbytes-int : Nat SpectecTerminal -> SpectecTerminals ."
      ; "  op builtin.nbytes-float : Nat SpectecTerminal -> SpectecTerminals ."
      ; "  op builtin.inv-nbytes-int : Nat SpectecTerminals -> SpectecTerminal ."
      ; "  op builtin.inv-nbytes-float : Nat SpectecTerminals -> SpectecTerminal ."
      ; "  eq builtin.nbytes-int(NB_N, numx5f.wrap_(NB_PAYLOAD)) = builtin.nbytes-int(NB_N, NB_PAYLOAD) ."
      ; "  ceq builtin.nbytes-int(NB_N, NB_I) = defibytesx5fx(NB_N, iN.wrap_(NB_I))"
      ; "    if _<_(NB_I, _^_(2, NB_N)) ."
      ; "  ceq builtin.nbytes-int(NB_N, iN.wrap_(NB_I)) = defibytesx5fx(NB_N, iN.wrap_(NB_I))"
      ; "    if _<_(NB_I, _^_(2, NB_N)) ."
      ; "  eq builtin.nbytes-float(NB_N, numx5f.wrap_(NB_PAYLOAD)) = builtin.nbytes-float(NB_N, NB_PAYLOAD) ."
      ; "  eq builtin.nbytes-float(NB_N, fN.pos_(FB_MAG)) = deffbytesx5fx(NB_N, fN.pos_(FB_MAG)) ."
      ; "  eq builtin.nbytes-float(NB_N, fN.neg_(FB_MAG)) = deffbytesx5fx(NB_N, fN.neg_(FB_MAG)) ."
      ; "  ceq builtin.inv-nbytes-int(NB_N, NB_BYTES) = numx5f.wrap_(NB_RAW)"
      ; "    if _rem_(NB_N, 8) = 0"
      ; "       /\\ len(NB_BYTES) = _quo_(NB_N, 8)"
      ; "       /\\ typecheckSeq(NB_BYTES, syn-byte)"
      ; "       /\\ NB_RAW := builtin.inv-ibytes-aux(NB_BYTES, 1, 0) ."
      ; "  ceq builtin.inv-nbytes-float(NB_N, NB_BYTES) = numx5f.wrap_(builtin.float-from-bits(NB_N, NB_RAW))"
      ; "    if _rem_(NB_N, 8) = 0"
      ; "       /\\ len(NB_BYTES) = _quo_(NB_N, 8)"
        ; "       /\\ typecheckSeq(NB_BYTES, syn-byte)"
        ; "       /\\ NB_RAW := builtin.inv-ibytes-aux(NB_BYTES, 1, 0) ."
        ]
      else
        [])
    @
    (if has_storage_const_bytes then
      [ ""
      ; "  --- Implemented builtin family: composite storage/const bytes."
      ; "  vars ZB_N ZB_RAW : Nat ."
      ; "  var ZB_PAYLOAD : SpectecTerminal ."
      ; "  var ZB_BYTES : SpectecTerminals ."
      ; "  op builtin.zbytes-pack : Nat SpectecTerminal -> SpectecTerminals ."
      ; "  op builtin.inv-zbytes-pack : Nat SpectecTerminals -> SpectecTerminal ."
      ; "  eq builtin.zbytes-pack(ZB_N, litx5f.wrap_(ZB_PAYLOAD)) = builtin.zbytes-pack(ZB_N, ZB_PAYLOAD) ."
      ; "  eq builtin.zbytes-pack(ZB_N, packx5f.wrap_(ZB_PAYLOAD)) = builtin.zbytes-pack(ZB_N, ZB_PAYLOAD) ."
      ; "  ceq builtin.zbytes-pack(ZB_N, iN.wrap_(ZB_RAW)) = defibytesx5fx(ZB_N, iN.wrap_(ZB_RAW))"
      ; "    if _<_(ZB_RAW, _^_(2, ZB_N)) ."
      ; "  ceq builtin.zbytes-pack(ZB_N, ZB_RAW) = defibytesx5fx(ZB_N, iN.wrap_(ZB_RAW))"
      ; "    if _<_(ZB_RAW, _^_(2, ZB_N)) ."
      ; "  ceq builtin.inv-zbytes-pack(ZB_N, ZB_BYTES) = packx5f.wrap_(ZB_RAW)"
      ; "    if _rem_(ZB_N, 8) = 0"
      ; "       /\\ len(ZB_BYTES) = _quo_(ZB_N, 8)"
      ; "       /\\ typecheckSeq(ZB_BYTES, syn-byte)"
      ; "       /\\ ZB_RAW := builtin.inv-ibytes-aux(ZB_BYTES, 1, 0) ."
      ]
    else
      [])
    @
    (if has_lanes then
      [ ""
      ; "  --- Implemented builtin family: vector lane splitting/reassembly."
      ; "  vars LN_W LN_COUNT LN_RAW LN_SCALE LN_ACC : Nat ."
      ; "  var LN_LT : SpectecTerminal ."
      ; "  var LN_PAYLOAD : SpectecTerminal ."
      ; "  var LN_HEAD : SpectecTerminal ."
      ; "  var LN_MAG : SpectecTerminal ."
      ; "  vars LN_LANES LN_TAIL : SpectecTerminals ."
      ; "  op builtin.lane-width : SpectecTerminal -> Nat ."
      ; "  op builtin.vec-raw : SpectecTerminal -> Nat ."
      ; "  op builtin.lane-from-bits : SpectecTerminal Nat -> SpectecTerminal ."
      ; "  op builtin.lane-to-bits : SpectecTerminal SpectecTerminal -> Nat ."
      ; "  op builtin.lanes-aux : SpectecTerminal Nat Nat Nat -> SpectecTerminals ."
      ; "  op builtin.inv-lanes-aux : SpectecTerminal Nat SpectecTerminals Nat Nat -> Nat ."
      ; "  eq builtin.lane-width(numtype.i32) = 32 ."
      ; "  eq builtin.lane-width(numtype.i64) = 64 ."
      ; "  eq builtin.lane-width(numtype.f32) = 32 ."
      ; "  eq builtin.lane-width(numtype.f64) = 64 ."
      ; "  eq builtin.lane-width(packtype.i8) = 8 ."
      ; "  eq builtin.lane-width(packtype.i16) = 16 ."
      ; "  eq builtin.vec-raw(vecx5f.wrap_(vN.wrap_(LN_RAW))) = LN_RAW ."
      ; "  eq builtin.vec-raw(vecx5f.wrap_(LN_RAW)) = LN_RAW ."
      ; "  eq builtin.vec-raw(vN.wrap_(LN_RAW)) = LN_RAW ."
      ; "  ceq builtin.lane-from-bits(numtype.i32, LN_RAW) = iN.wrap_(LN_RAW)"
      ; "    if _<_(LN_RAW, _^_(2, 32)) ."
      ; "  ceq builtin.lane-from-bits(numtype.i64, LN_RAW) = iN.wrap_(LN_RAW)"
      ; "    if _<_(LN_RAW, _^_(2, 64)) ."
      ; "  ceq builtin.lane-from-bits(packtype.i8, LN_RAW) = iN.wrap_(LN_RAW)"
      ; "    if _<_(LN_RAW, _^_(2, 8)) ."
      ; "  ceq builtin.lane-from-bits(packtype.i16, LN_RAW) = iN.wrap_(LN_RAW)"
      ; "    if _<_(LN_RAW, _^_(2, 16)) ."
      ; "  ceq builtin.lane-from-bits(numtype.f32, LN_RAW) = builtin.float-from-bits(32, LN_RAW)"
      ; "    if _<_(LN_RAW, _^_(2, 32)) ."
      ; "  ceq builtin.lane-from-bits(numtype.f64, LN_RAW) = builtin.float-from-bits(64, LN_RAW)"
      ; "    if _<_(LN_RAW, _^_(2, 64)) ."
      ; "  eq builtin.lane-to-bits(LN_LT, lanex5f.wrap_(LN_PAYLOAD)) = builtin.lane-to-bits(LN_LT, LN_PAYLOAD) ."
      ; "  eq builtin.lane-to-bits(numtype.i32, numx5f.wrap_(LN_PAYLOAD)) = builtin.lane-to-bits(numtype.i32, LN_PAYLOAD) ."
      ; "  eq builtin.lane-to-bits(numtype.i64, numx5f.wrap_(LN_PAYLOAD)) = builtin.lane-to-bits(numtype.i64, LN_PAYLOAD) ."
      ; "  eq builtin.lane-to-bits(numtype.f32, numx5f.wrap_(LN_PAYLOAD)) = builtin.lane-to-bits(numtype.f32, LN_PAYLOAD) ."
      ; "  eq builtin.lane-to-bits(numtype.f64, numx5f.wrap_(LN_PAYLOAD)) = builtin.lane-to-bits(numtype.f64, LN_PAYLOAD) ."
      ; "  eq builtin.lane-to-bits(packtype.i8, packx5f.wrap_(LN_PAYLOAD)) = builtin.lane-to-bits(packtype.i8, LN_PAYLOAD) ."
      ; "  eq builtin.lane-to-bits(packtype.i16, packx5f.wrap_(LN_PAYLOAD)) = builtin.lane-to-bits(packtype.i16, LN_PAYLOAD) ."
      ; "  ceq builtin.lane-to-bits(numtype.i32, LN_RAW) = LN_RAW"
      ; "    if _<_(LN_RAW, _^_(2, 32)) ."
      ; "  ceq builtin.lane-to-bits(numtype.i32, iN.wrap_(LN_RAW)) = LN_RAW"
      ; "    if _<_(LN_RAW, _^_(2, 32)) ."
      ; "  ceq builtin.lane-to-bits(numtype.i64, LN_RAW) = LN_RAW"
      ; "    if _<_(LN_RAW, _^_(2, 64)) ."
      ; "  ceq builtin.lane-to-bits(numtype.i64, iN.wrap_(LN_RAW)) = LN_RAW"
      ; "    if _<_(LN_RAW, _^_(2, 64)) ."
      ; "  ceq builtin.lane-to-bits(packtype.i8, LN_RAW) = LN_RAW"
      ; "    if _<_(LN_RAW, _^_(2, 8)) ."
      ; "  ceq builtin.lane-to-bits(packtype.i8, iN.wrap_(LN_RAW)) = LN_RAW"
      ; "    if _<_(LN_RAW, _^_(2, 8)) ."
      ; "  ceq builtin.lane-to-bits(packtype.i16, LN_RAW) = LN_RAW"
      ; "    if _<_(LN_RAW, _^_(2, 16)) ."
      ; "  ceq builtin.lane-to-bits(packtype.i16, iN.wrap_(LN_RAW)) = LN_RAW"
      ; "    if _<_(LN_RAW, _^_(2, 16)) ."
      ; "  ceq builtin.lane-to-bits(numtype.f32, fN.pos_(LN_MAG)) = builtin.float-to-bits(32, fN.pos_(LN_MAG))"
      ; "    if (builtin.fnmag-valid(32, LN_MAG)) = true ."
      ; "  ceq builtin.lane-to-bits(numtype.f32, fN.neg_(LN_MAG)) = builtin.float-to-bits(32, fN.neg_(LN_MAG))"
      ; "    if (builtin.fnmag-valid(32, LN_MAG)) = true ."
      ; "  ceq builtin.lane-to-bits(numtype.f64, fN.pos_(LN_MAG)) = builtin.float-to-bits(64, fN.pos_(LN_MAG))"
      ; "    if (builtin.fnmag-valid(64, LN_MAG)) = true ."
      ; "  ceq builtin.lane-to-bits(numtype.f64, fN.neg_(LN_MAG)) = builtin.float-to-bits(64, fN.neg_(LN_MAG))"
      ; "    if (builtin.fnmag-valid(64, LN_MAG)) = true ."
      ; "  eq builtin.lanes-aux(LN_LT, LN_W, 0, LN_RAW) = eps ."
      ; "  ceq builtin.lanes-aux(LN_LT, LN_W, LN_COUNT, LN_RAW) ="
      ; "      builtin.lane-from-bits(LN_LT, _rem_(LN_RAW, _^_(2, LN_W)))"
      ; "      builtin.lanes-aux(LN_LT, LN_W, _-_(LN_COUNT, 1), _quo_(LN_RAW, _^_(2, LN_W)))"
      ; "    if _>_(LN_COUNT, 0) ."
      ; "  eq builtin.inv-lanes-aux(LN_LT, LN_W, eps, LN_SCALE, LN_ACC) = LN_ACC ."
      ; "  ceq builtin.inv-lanes-aux(LN_LT, LN_W, LN_HEAD LN_TAIL, LN_SCALE, LN_ACC) ="
      ; "      builtin.inv-lanes-aux(LN_LT, LN_W, LN_TAIL, _*_(LN_SCALE, _^_(2, LN_W)), _+_(LN_ACC, _*_(LN_RAW, LN_SCALE)))"
      ; "    if LN_RAW := builtin.lane-to-bits(LN_LT, LN_HEAD)"
      ; "       /\\ _<_(LN_RAW, _^_(2, LN_W)) ."
      ]
    else
      [])


let implemented_equations ~has_entry =
    (if has_entry "ibits_" then
       [ ""
       ; "  ceq defibitsx5fx(BI_N, iN.wrap_(BI_I)) = builtin.ibits-aux(BI_N, BI_I)"
       ; "    if _<_(BI_I, _^_(2, BI_N)) ."
       ]
     else
       [])
    @
    (if has_entry "inv_ibits_" then
       [ ""
       ; "  ceq definvx5fxibitsx5fx(BI_N, BI_BITS) = iN.wrap_(BI_RESULT)"
       ; "    if len(BI_BITS) = BI_N"
       ; "       /\\ typecheckSeq(BI_BITS, syn-bit)"
       ; "       /\\ BI_RESULT := builtin.inv-ibits-aux(BI_BITS, 0) ."
       ]
     else
       [])
    @
    (if has_entry "fbits_" then
      [ ""
      ; "  ceq deffbitsx5fx(FB_N, fN.pos_(FB_MAG)) = builtin.ibits-aux(FB_N, FB_RAW)"
      ; "    if (builtin.fnmag-valid(FB_N, FB_MAG)) = true"
      ; "       /\\ FB_RAW := builtin.float-to-bits(FB_N, fN.pos_(FB_MAG)) ."
      ; "  ceq deffbitsx5fx(FB_N, fN.neg_(FB_MAG)) = builtin.ibits-aux(FB_N, FB_RAW)"
      ; "    if (builtin.fnmag-valid(FB_N, FB_MAG)) = true"
      ; "       /\\ FB_RAW := builtin.float-to-bits(FB_N, fN.neg_(FB_MAG)) ."
      ]
    else
      [])
    @
    (if has_entry "inv_fbits_" then
      [ ""
      ; "  ceq definvx5fxfbitsx5fx(FB_N, FB_BITS) = builtin.float-from-bits(FB_N, FB_RAW)"
      ; "    if len(FB_BITS) = FB_N"
      ; "       /\\ typecheckSeq(FB_BITS, syn-bit)"
      ; "       /\\ FB_RAW := builtin.inv-ibits-aux(FB_BITS, 0) ."
      ]
    else
      [])
    @
    (if has_entry "ibytes_" then
       [ ""
       ; "  ceq defibytesx5fx(BY_N, iN.wrap_(BY_I)) = builtin.ibytes-aux(_quo_(BY_N, 8), BY_I)"
       ; "    if _rem_(BY_N, 8) = 0"
       ; "       /\\ _<_(BY_I, _^_(2, BY_N)) ."
       ]
     else
       [])
    @
    (if has_entry "inv_ibytes_" then
      [ ""
      ; "  ceq definvx5fxibytesx5fx(BY_N, BY_BYTES) = iN.wrap_(BY_RESULT)"
      ; "    if _rem_(BY_N, 8) = 0"
      ; "       /\\ len(BY_BYTES) = _quo_(BY_N, 8)"
      ; "       /\\ typecheckSeq(BY_BYTES, syn-byte)"
      ; "       /\\ BY_RESULT := builtin.inv-ibytes-aux(BY_BYTES, 1, 0) ."
      ]
    else
      [])
    @
    (if has_entry "fbytes_" then
      [ ""
      ; "  ceq deffbytesx5fx(FB_N, fN.pos_(FB_MAG)) = builtin.ibytes-aux(_quo_(FB_N, 8), FB_RAW)"
      ; "    if _rem_(FB_N, 8) = 0"
      ; "       /\\ (builtin.fnmag-valid(FB_N, FB_MAG)) = true"
      ; "       /\\ FB_RAW := builtin.float-to-bits(FB_N, fN.pos_(FB_MAG)) ."
      ; "  ceq deffbytesx5fx(FB_N, fN.neg_(FB_MAG)) = builtin.ibytes-aux(_quo_(FB_N, 8), FB_RAW)"
      ; "    if _rem_(FB_N, 8) = 0"
      ; "       /\\ (builtin.fnmag-valid(FB_N, FB_MAG)) = true"
      ; "       /\\ FB_RAW := builtin.float-to-bits(FB_N, fN.neg_(FB_MAG)) ."
      ]
    else
      [])
    @
    (if has_entry "inv_fbytes_" then
      [ ""
      ; "  ceq definvx5fxfbytesx5fx(FB_N, FB_BYTES) = builtin.float-from-bits(FB_N, FB_RAW)"
      ; "    if _rem_(FB_N, 8) = 0"
      ; "       /\\ len(FB_BYTES) = _quo_(FB_N, 8)"
      ; "       /\\ typecheckSeq(FB_BYTES, syn-byte)"
      ; "       /\\ FB_RAW := builtin.inv-ibytes-aux(FB_BYTES, 1, 0) ."
      ]
    else
      [])
    @
    (if has_entry "nbytes_" then
      [ ""
      ; "  eq defnbytesx5fx(numtype.i32, NB_PAYLOAD) = builtin.nbytes-int(32, NB_PAYLOAD) ."
      ; "  eq defnbytesx5fx(numtype.i64, NB_PAYLOAD) = builtin.nbytes-int(64, NB_PAYLOAD) ."
      ; "  eq defnbytesx5fx(numtype.f32, NB_PAYLOAD) = builtin.nbytes-float(32, NB_PAYLOAD) ."
      ; "  eq defnbytesx5fx(numtype.f64, NB_PAYLOAD) = builtin.nbytes-float(64, NB_PAYLOAD) ."
      ]
    else
      [])
    @
    (if has_entry "inv_nbytes_" then
      [ ""
      ; "  eq definvx5fxnbytesx5fx(numtype.i32, NB_BYTES) = builtin.inv-nbytes-int(32, NB_BYTES) ."
      ; "  eq definvx5fxnbytesx5fx(numtype.i64, NB_BYTES) = builtin.inv-nbytes-int(64, NB_BYTES) ."
      ; "  eq definvx5fxnbytesx5fx(numtype.f32, NB_BYTES) = builtin.inv-nbytes-float(32, NB_BYTES) ."
      ; "  eq definvx5fxnbytesx5fx(numtype.f64, NB_BYTES) = builtin.inv-nbytes-float(64, NB_BYTES) ."
      ]
    else
      [])
    @
    (if has_entry "reinterpret__" then
      [ ""
      ; "  eq defreinterpretx5fxx5fx(numtype.i32, numtype.f32, NB_PAYLOAD) ="
      ; "      definvx5fxnbytesx5fx(numtype.f32, defnbytesx5fx(numtype.i32, NB_PAYLOAD)) ."
      ; "  eq defreinterpretx5fxx5fx(numtype.f32, numtype.i32, NB_PAYLOAD) ="
      ; "      definvx5fxnbytesx5fx(numtype.i32, defnbytesx5fx(numtype.f32, NB_PAYLOAD)) ."
      ; "  eq defreinterpretx5fxx5fx(numtype.i64, numtype.f64, NB_PAYLOAD) ="
      ; "      definvx5fxnbytesx5fx(numtype.f64, defnbytesx5fx(numtype.i64, NB_PAYLOAD)) ."
      ; "  eq defreinterpretx5fxx5fx(numtype.f64, numtype.i64, NB_PAYLOAD) ="
      ; "      definvx5fxnbytesx5fx(numtype.i64, defnbytesx5fx(numtype.f64, NB_PAYLOAD)) ."
      ]
    else
      [])
    @
    (if has_entry "vbytes_" then
      [ ""
      ; "  ceq defvbytesx5fx(vectype.v128, vecx5f.wrap_(BY_I)) ="
      ; "      builtin.ibytes-aux(_quo_(defvsize(vectype.v128), 8), BY_I)"
      ; "    if _<_(BY_I, _^_(2, defvsize(vectype.v128))) ."
      ; "  ceq defvbytesx5fx(vectype.v128, vecx5f.wrap_(vN.wrap_(BY_I))) ="
      ; "      builtin.ibytes-aux(_quo_(defvsize(vectype.v128), 8), BY_I)"
      ; "    if _<_(BY_I, _^_(2, defvsize(vectype.v128))) ."
      ]
    else
      [])
    @
      (if has_entry "inv_vbytes_" then
        [ ""
        ; "  ceq definvx5fxvbytesx5fx(vectype.v128, BY_BYTES) = vecx5f.wrap_(BY_RESULT)"
        ; "    if len(BY_BYTES) = _quo_(defvsize(vectype.v128), 8)"
        ; "       /\\ typecheckSeq(BY_BYTES, syn-byte)"
        ; "       /\\ BY_RESULT := builtin.inv-ibytes-aux(BY_BYTES, 1, 0) ."
        ]
      else
        [])
    @
    (if has_entry "zbytes_" then
      [ ""
      ; "  eq defzbytesx5fx(numtype.i32, ZB_PAYLOAD) = defnbytesx5fx(numtype.i32, ZB_PAYLOAD) ."
      ; "  eq defzbytesx5fx(numtype.i64, ZB_PAYLOAD) = defnbytesx5fx(numtype.i64, ZB_PAYLOAD) ."
      ; "  eq defzbytesx5fx(numtype.f32, ZB_PAYLOAD) = defnbytesx5fx(numtype.f32, ZB_PAYLOAD) ."
      ; "  eq defzbytesx5fx(numtype.f64, ZB_PAYLOAD) = defnbytesx5fx(numtype.f64, ZB_PAYLOAD) ."
      ; "  eq defzbytesx5fx(vectype.v128, ZB_PAYLOAD) = defvbytesx5fx(vectype.v128, ZB_PAYLOAD) ."
      ; "  eq defzbytesx5fx(packtype.i8, ZB_PAYLOAD) = builtin.zbytes-pack(8, ZB_PAYLOAD) ."
      ; "  eq defzbytesx5fx(packtype.i16, ZB_PAYLOAD) = builtin.zbytes-pack(16, ZB_PAYLOAD) ."
      ]
    else
      [])
    @
    (if has_entry "cbytes_" then
      [ ""
      ; "  eq defcbytesx5fx(numtype.i32, ZB_PAYLOAD) = defnbytesx5fx(numtype.i32, ZB_PAYLOAD) ."
      ; "  eq defcbytesx5fx(numtype.i64, ZB_PAYLOAD) = defnbytesx5fx(numtype.i64, ZB_PAYLOAD) ."
      ; "  eq defcbytesx5fx(numtype.f32, ZB_PAYLOAD) = defnbytesx5fx(numtype.f32, ZB_PAYLOAD) ."
      ; "  eq defcbytesx5fx(numtype.f64, ZB_PAYLOAD) = defnbytesx5fx(numtype.f64, ZB_PAYLOAD) ."
      ; "  eq defcbytesx5fx(vectype.v128, ZB_PAYLOAD) = defvbytesx5fx(vectype.v128, ZB_PAYLOAD) ."
      ]
    else
      [])
    @
    (if has_entry "inv_zbytes_" then
      [ ""
      ; "  eq definvx5fxzbytesx5fx(numtype.i32, ZB_BYTES) = definvx5fxnbytesx5fx(numtype.i32, ZB_BYTES) ."
      ; "  eq definvx5fxzbytesx5fx(numtype.i64, ZB_BYTES) = definvx5fxnbytesx5fx(numtype.i64, ZB_BYTES) ."
      ; "  eq definvx5fxzbytesx5fx(numtype.f32, ZB_BYTES) = definvx5fxnbytesx5fx(numtype.f32, ZB_BYTES) ."
      ; "  eq definvx5fxzbytesx5fx(numtype.f64, ZB_BYTES) = definvx5fxnbytesx5fx(numtype.f64, ZB_BYTES) ."
      ; "  eq definvx5fxzbytesx5fx(vectype.v128, ZB_BYTES) = definvx5fxvbytesx5fx(vectype.v128, ZB_BYTES) ."
      ; "  eq definvx5fxzbytesx5fx(packtype.i8, ZB_BYTES) = builtin.inv-zbytes-pack(8, ZB_BYTES) ."
      ; "  eq definvx5fxzbytesx5fx(packtype.i16, ZB_BYTES) = builtin.inv-zbytes-pack(16, ZB_BYTES) ."
      ]
    else
      [])
    @
    (if has_entry "inv_cbytes_" then
      [ ""
      ; "  eq definvx5fxcbytesx5fx(numtype.i32, ZB_BYTES) = definvx5fxnbytesx5fx(numtype.i32, ZB_BYTES) ."
      ; "  eq definvx5fxcbytesx5fx(numtype.i64, ZB_BYTES) = definvx5fxnbytesx5fx(numtype.i64, ZB_BYTES) ."
      ; "  eq definvx5fxcbytesx5fx(numtype.f32, ZB_BYTES) = definvx5fxnbytesx5fx(numtype.f32, ZB_BYTES) ."
      ; "  eq definvx5fxcbytesx5fx(numtype.f64, ZB_BYTES) = definvx5fxnbytesx5fx(numtype.f64, ZB_BYTES) ."
      ; "  eq definvx5fxcbytesx5fx(vectype.v128, ZB_BYTES) = definvx5fxvbytesx5fx(vectype.v128, ZB_BYTES) ."
      ]
    else
      [])
    @
    (if has_entry "lanes_" then
      [ ""
      ; "  ceq deflanesx5fx(shape._x_(LN_LT, dim.wrap_(LN_COUNT)), LN_PAYLOAD) ="
      ; "      builtin.lanes-aux(LN_LT, LN_W, LN_COUNT, LN_RAW)"
      ; "    if LN_W := builtin.lane-width(LN_LT)"
      ; "       /\\ _*_(LN_W, LN_COUNT) = 128"
      ; "       /\\ LN_RAW := builtin.vec-raw(LN_PAYLOAD)"
      ; "       /\\ _<_(LN_RAW, _^_(2, 128)) ."
      ]
    else
      [])
    @
    (if has_entry "inv_lanes_" then
      [ ""
      ; "  ceq definvx5fxlanesx5fx(shape._x_(LN_LT, dim.wrap_(LN_COUNT)), LN_LANES) ="
      ; "      vecx5f.wrap_(builtin.inv-lanes-aux(LN_LT, LN_W, LN_LANES, 1, 0))"
      ; "    if LN_W := builtin.lane-width(LN_LT)"
      ; "       /\\ _*_(LN_W, LN_COUNT) = 128"
      ; "       /\\ len(LN_LANES) = LN_COUNT ."
      ]
    else
      [])
