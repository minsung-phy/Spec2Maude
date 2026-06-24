let helper_decls
    ~has_bits
    ~has_bytes
    ~has_integer_conversion
    ~has_integer_bit_count
    ~has_integer_bitwise
    ~has_integer_shift_rotate
    ~has_integer_narrow
    ~has_integer_average
    ~has_integer_q15
    ~has_rational_integer =
    (if has_bits then
       [ ""
       ; "  --- Implemented builtin family: integer bits, MSB first."
       ; "  vars BI_N BI_I BI_ACC BI_BIT BI_RESULT : Nat ."
       ; "  var BI_BITS : SpectecTerminals ."
       ; "  op builtin.ibits-aux : Nat Nat -> SpectecTerminals ."
       ; "  op builtin.inv-ibits-aux : SpectecTerminals Nat -> Nat ."
       ; "  eq builtin.ibits-aux(0, BI_I) = eps ."
       ; "  ceq builtin.ibits-aux(BI_N, BI_I) ="
       ; "      _rem_(_quo_(BI_I, _^_(2, _-_(BI_N, 1))), 2) builtin.ibits-aux(_-_(BI_N, 1), BI_I)"
       ; "    if _>_(BI_N, 0) ."
       ; "  eq builtin.inv-ibits-aux(eps, BI_ACC) = BI_ACC ."
       ; "  ceq builtin.inv-ibits-aux(BI_BIT BI_BITS, BI_ACC) ="
       ; "      builtin.inv-ibits-aux(BI_BITS, _+_(_*_(BI_ACC, 2), BI_BIT))"
       ; "    if typecheck(BI_BIT, syn-bit) ."
       ]
     else
       [])
    @
    (if has_bytes then
      [ ""
      ; "  --- Implemented builtin family: integer bytes, little endian."
      ; "  vars BY_N BY_I BY_COUNT BY_ACC BY_SCALE BY_BYTE BY_RESULT : Nat ."
      ; "  var BY_BYTES : SpectecTerminals ."
      ; "  op builtin.ibytes-aux : Nat Nat -> SpectecTerminals ."
      ; "  op builtin.inv-ibytes-aux : SpectecTerminals Nat Nat -> Nat ."
      ; "  eq builtin.ibytes-aux(0, BY_I) = eps ."
      ; "  ceq builtin.ibytes-aux(BY_COUNT, BY_I) ="
      ; "      _rem_(BY_I, 256) builtin.ibytes-aux(_-_(BY_COUNT, 1), _quo_(BY_I, 256))"
      ; "    if _>_(BY_COUNT, 0) ."
      ; "  eq builtin.inv-ibytes-aux(eps, BY_SCALE, BY_ACC) = BY_ACC ."
      ; "  ceq builtin.inv-ibytes-aux(BY_BYTE BY_BYTES, BY_SCALE, BY_ACC) ="
      ; "      builtin.inv-ibytes-aux(BY_BYTES, _*_(BY_SCALE, 256), _+_(BY_ACC, _*_(BY_BYTE, BY_SCALE)))"
      ; "    if typecheck(BY_BYTE, syn-byte) ."
      ]
    else
      [])
    @
    (if has_integer_conversion then
      [ ""
      ; "  --- Implemented builtin family: integer wrap/extend conversions."
      ; "  vars BW_M BW_N BW_I : Nat ."
      ; "  vars BE_M BE_N BE_I : Nat ."
      ; "  op builtin.sign-extend-nat : Nat Nat Nat -> Nat ."
      ; "  ceq builtin.sign-extend-nat(BE_M, BE_N, BE_I) = BE_I"
      ; "    if _>_(BE_M, 0)"
      ; "       /\\ _<_(BE_M, BE_N)"
      ; "       /\\ _<_(BE_I, _^_(2, BE_M))"
      ; "       /\\ _<_(BE_I, _^_(2, _-_(BE_M, 1))) ."
      ; "  ceq builtin.sign-extend-nat(BE_M, BE_N, BE_I) ="
      ; "      _-_(_+_(BE_I, _^_(2, BE_N)), _^_(2, BE_M))"
      ; "    if _>_(BE_M, 0)"
      ; "       /\\ _<_(BE_M, BE_N)"
      ; "       /\\ _<_(BE_I, _^_(2, BE_M))"
      ; "       /\\ _>=_(BE_I, _^_(2, _-_(BE_M, 1))) ."
      ]
    else
      [])
    @
    (if has_integer_bit_count then
      [ ""
      ; "  --- Implemented builtin family: integer bit-count operations."
      ; "  vars BC_N BC_I BC_ACC : Nat ."
      ; "  var BC_BITS : SpectecTerminals ."
      ; "  op builtin.iclz-bits : SpectecTerminals Nat -> Nat ."
      ; "  op builtin.ictz-bits : SpectecTerminals Nat -> Nat ."
      ; "  op builtin.ipopcnt-bits : SpectecTerminals Nat -> Nat ."
      ; "  eq builtin.iclz-bits(eps, BC_ACC) = BC_ACC ."
      ; "  eq builtin.iclz-bits(1 BC_BITS, BC_ACC) = BC_ACC ."
      ; "  eq builtin.iclz-bits(0 BC_BITS, BC_ACC) = builtin.iclz-bits(BC_BITS, _+_(BC_ACC, 1)) ."
      ; "  eq builtin.ictz-bits(eps, BC_ACC) = BC_ACC ."
      ; "  eq builtin.ictz-bits(0 BC_BITS, BC_ACC) = builtin.ictz-bits(BC_BITS, _+_(BC_ACC, 1)) ."
      ; "  eq builtin.ictz-bits(1 BC_BITS, BC_ACC) = builtin.ictz-bits(BC_BITS, 0) ."
      ; "  eq builtin.ipopcnt-bits(eps, BC_ACC) = BC_ACC ."
      ; "  eq builtin.ipopcnt-bits(0 BC_BITS, BC_ACC) = builtin.ipopcnt-bits(BC_BITS, BC_ACC) ."
      ; "  eq builtin.ipopcnt-bits(1 BC_BITS, BC_ACC) = builtin.ipopcnt-bits(BC_BITS, _+_(BC_ACC, 1)) ."
      ]
    else
      [])
    @
    (if has_integer_bitwise then
      [ ""
      ; "  --- Implemented builtin family: integer bitwise operations."
      ; "  vars BT_N BT_I BT_J BT_K : Nat ."
      ; "  vars BT_BITS BT_BITS1 BT_BITS2 : SpectecTerminals ."
      ; "  op builtin.inot-bits : SpectecTerminals -> SpectecTerminals ."
      ; "  op builtin.irev-bits : SpectecTerminals SpectecTerminals -> SpectecTerminals ."
      ; "  op builtin.iand-bits : SpectecTerminals SpectecTerminals -> SpectecTerminals ."
      ; "  op builtin.iandnot-bits : SpectecTerminals SpectecTerminals -> SpectecTerminals ."
      ; "  op builtin.ior-bits : SpectecTerminals SpectecTerminals -> SpectecTerminals ."
      ; "  op builtin.ixor-bits : SpectecTerminals SpectecTerminals -> SpectecTerminals ."
      ; "  eq builtin.inot-bits(eps) = eps ."
      ; "  eq builtin.inot-bits(0 BT_BITS) = 1 builtin.inot-bits(BT_BITS) ."
      ; "  eq builtin.inot-bits(1 BT_BITS) = 0 builtin.inot-bits(BT_BITS) ."
      ; "  eq builtin.irev-bits(eps, BT_BITS2) = BT_BITS2 ."
      ; "  eq builtin.irev-bits(0 BT_BITS1, BT_BITS2) = builtin.irev-bits(BT_BITS1, 0 BT_BITS2) ."
      ; "  eq builtin.irev-bits(1 BT_BITS1, BT_BITS2) = builtin.irev-bits(BT_BITS1, 1 BT_BITS2) ."
      ; "  eq builtin.iand-bits(eps, eps) = eps ."
      ; "  eq builtin.iand-bits(0 BT_BITS1, 0 BT_BITS2) = 0 builtin.iand-bits(BT_BITS1, BT_BITS2) ."
      ; "  eq builtin.iand-bits(0 BT_BITS1, 1 BT_BITS2) = 0 builtin.iand-bits(BT_BITS1, BT_BITS2) ."
      ; "  eq builtin.iand-bits(1 BT_BITS1, 0 BT_BITS2) = 0 builtin.iand-bits(BT_BITS1, BT_BITS2) ."
      ; "  eq builtin.iand-bits(1 BT_BITS1, 1 BT_BITS2) = 1 builtin.iand-bits(BT_BITS1, BT_BITS2) ."
      ; "  eq builtin.iandnot-bits(eps, eps) = eps ."
      ; "  eq builtin.iandnot-bits(0 BT_BITS1, 0 BT_BITS2) = 0 builtin.iandnot-bits(BT_BITS1, BT_BITS2) ."
      ; "  eq builtin.iandnot-bits(0 BT_BITS1, 1 BT_BITS2) = 0 builtin.iandnot-bits(BT_BITS1, BT_BITS2) ."
      ; "  eq builtin.iandnot-bits(1 BT_BITS1, 0 BT_BITS2) = 1 builtin.iandnot-bits(BT_BITS1, BT_BITS2) ."
      ; "  eq builtin.iandnot-bits(1 BT_BITS1, 1 BT_BITS2) = 0 builtin.iandnot-bits(BT_BITS1, BT_BITS2) ."
      ; "  eq builtin.ior-bits(eps, eps) = eps ."
      ; "  eq builtin.ior-bits(0 BT_BITS1, 0 BT_BITS2) = 0 builtin.ior-bits(BT_BITS1, BT_BITS2) ."
      ; "  eq builtin.ior-bits(0 BT_BITS1, 1 BT_BITS2) = 1 builtin.ior-bits(BT_BITS1, BT_BITS2) ."
      ; "  eq builtin.ior-bits(1 BT_BITS1, 0 BT_BITS2) = 1 builtin.ior-bits(BT_BITS1, BT_BITS2) ."
      ; "  eq builtin.ior-bits(1 BT_BITS1, 1 BT_BITS2) = 1 builtin.ior-bits(BT_BITS1, BT_BITS2) ."
      ; "  eq builtin.ixor-bits(eps, eps) = eps ."
      ; "  eq builtin.ixor-bits(0 BT_BITS1, 0 BT_BITS2) = 0 builtin.ixor-bits(BT_BITS1, BT_BITS2) ."
      ; "  eq builtin.ixor-bits(0 BT_BITS1, 1 BT_BITS2) = 1 builtin.ixor-bits(BT_BITS1, BT_BITS2) ."
      ; "  eq builtin.ixor-bits(1 BT_BITS1, 0 BT_BITS2) = 1 builtin.ixor-bits(BT_BITS1, BT_BITS2) ."
      ; "  eq builtin.ixor-bits(1 BT_BITS1, 1 BT_BITS2) = 0 builtin.ixor-bits(BT_BITS1, BT_BITS2) ."
      ]
    else
      [])
    @
    (if has_integer_shift_rotate then
      [ ""
      ; "  --- Implemented builtin family: integer shift/rotate operations."
      ; "  var SH_N : NzNat ."
      ; "  vars SH_I SH_J SH_K : Nat ."
      ; "  op builtin.shift-count : NzNat Nat -> Nat ."
      ; "  eq builtin.shift-count(SH_N, SH_J) = _rem_(SH_J, SH_N) ."
      ]
    else
      [])
    @
    (if has_integer_narrow then
      [ ""
      ; "  --- Implemented builtin family: integer narrowing conversion."
      ; "  var NW_N : NzNat ."
      ; "  vars NW_M NW_I : Nat ."
      ]
    else
      [])
    @
    (if has_integer_average then
      [ ""
      ; "  --- Implemented builtin family: unsigned rounded integer average."
      ; "  vars AV_N AV_I AV_J : Nat ."
      ]
    else
      [])
    @
    (if has_integer_q15 then
      [ ""
      ; "  --- Implemented builtin family: signed i16 Q15 rounded multiply with saturation."
      ; "  vars Q15_N Q15_I Q15_J : Nat ."
      ; "  var Q15_X : Int ."
      ; "  var Q15_P : Nat ."
      ; "  op builtin.signed-nat : Nat Nat -> Int ."
      ; "  op builtin.floor-div-pow2-int : Int Nat -> Int ."
      ; "  op builtin.sat-s-int : Nat Int -> Int ."
      ; "  op builtin.wrap-s-int : Nat Int -> Nat ."
      ; "  ceq builtin.signed-nat(Q15_N, Q15_I) = Q15_I"
      ; "    if _>_(Q15_N, 0)"
      ; "       /\\ _<_(Q15_I, _^_(2, _-_(Q15_N, 1))) ."
      ; "  ceq builtin.signed-nat(Q15_N, Q15_I) = _-_(Q15_I, _^_(2, Q15_N))"
      ; "    if _>_(Q15_N, 0)"
      ; "       /\\ _>=_(Q15_I, _^_(2, _-_(Q15_N, 1)))"
      ; "       /\\ _<_(Q15_I, _^_(2, Q15_N)) ."
      ; "  ceq builtin.floor-div-pow2-int(Q15_X, Q15_P) = _quo_(Q15_X, Q15_P)"
      ; "    if _>=_(Q15_X, 0)"
      ; "       /\\ _>_(Q15_P, 0) ."
      ; "  ceq builtin.floor-div-pow2-int(Q15_X, Q15_P) = - _quo_(abs(Q15_X), Q15_P)"
      ; "    if _<_(Q15_X, 0)"
      ; "       /\\ _>_(Q15_P, 0)"
      ; "       /\\ _rem_(abs(Q15_X), Q15_P) = 0 ."
      ; "  ceq builtin.floor-div-pow2-int(Q15_X, Q15_P) = - _+_(_quo_(abs(Q15_X), Q15_P), 1)"
      ; "    if _<_(Q15_X, 0)"
      ; "       /\\ _>_(Q15_P, 0)"
      ; "       /\\ _>_(_rem_(abs(Q15_X), Q15_P), 0) ."
      ; "  ceq builtin.sat-s-int(Q15_N, Q15_X) = - _^_(2, _-_(Q15_N, 1))"
      ; "    if _>_(Q15_N, 0)"
      ; "       /\\ _<_(Q15_X, - _^_(2, _-_(Q15_N, 1))) ."
      ; "  ceq builtin.sat-s-int(Q15_N, Q15_X) = _-_(_^_(2, _-_(Q15_N, 1)), 1)"
      ; "    if _>_(Q15_N, 0)"
      ; "       /\\ _>_(Q15_X, _-_( _^_(2, _-_(Q15_N, 1)), 1)) ."
      ; "  ceq builtin.sat-s-int(Q15_N, Q15_X) = Q15_X"
      ; "    if _>_(Q15_N, 0)"
      ; "       /\\ _>=_(Q15_X, - _^_(2, _-_(Q15_N, 1)))"
      ; "       /\\ _<=_(Q15_X, _-_( _^_(2, _-_(Q15_N, 1)), 1)) ."
      ; "  ceq builtin.wrap-s-int(Q15_N, Q15_X) = Q15_X"
      ; "    if _>=_(Q15_X, 0) ."
      ; "  ceq builtin.wrap-s-int(Q15_N, Q15_X) = sd(_^_(2, Q15_N), abs(Q15_X))"
      ; "    if _<_(Q15_X, 0) ."
      ]
    else
      [])
    @
    (if has_rational_integer then
      [ ""
      ; "  --- Implemented builtin family: rational-to-integer helpers."
      ; "  var TZ_R : Rat ."
      ]
    else
      [])


let implemented_equations ~has_entry =
      (if has_entry "wrap__" then
         [ ""
         ; "  ceq defwrapx5fxx5fx(BW_M, BW_N, iN.wrap_(BW_I)) = iN.wrap_(_rem_(BW_I, _^_(2, BW_N)))"
      ; "    if _>_(BW_N, 0)"
      ; "       /\\ _<_(BW_N, BW_M)"
      ; "       /\\ _<_(BW_I, _^_(2, BW_M)) ."
       ]
     else
       [])
    @
    (if has_entry "extend__" then
      [ ""
      ; "  ceq defextendx5fxx5fx(BE_M, BE_N, sx.u, iN.wrap_(BE_I)) = iN.wrap_(BE_I)"
      ; "    if _<_(BE_M, BE_N)"
      ; "       /\\ _<_(BE_I, _^_(2, BE_M)) ."
      ; "  ceq defextendx5fxx5fx(BE_M, BE_N, sx.s, iN.wrap_(BE_I)) = iN.wrap_(builtin.sign-extend-nat(BE_M, BE_N, BE_I))"
      ; "    if _>_(BE_M, 0)"
      ; "       /\\ _<_(BE_M, BE_N)"
      ; "       /\\ _<_(BE_I, _^_(2, BE_M)) ."
      ]
    else
      [])
    @
    (if has_entry "iclz_" then
       [ ""
       ; "  ceq deficlzx5fx(BC_N, iN.wrap_(BC_I)) = iN.wrap_(builtin.iclz-bits(builtin.ibits-aux(BC_N, BC_I), 0))"
       ; "    if _>_(BC_N, 0)"
       ; "       /\\ _<_(BC_I, _^_(2, BC_N)) ."
       ]
     else
       [])
    @
    (if has_entry "ictz_" then
       [ ""
       ; "  ceq defictzx5fx(BC_N, iN.wrap_(BC_I)) = iN.wrap_(builtin.ictz-bits(builtin.ibits-aux(BC_N, BC_I), 0))"
       ; "    if _>_(BC_N, 0)"
       ; "       /\\ _<_(BC_I, _^_(2, BC_N)) ."
       ]
     else
       [])
    @
    (if has_entry "ipopcnt_" then
      [ ""
      ; "  ceq defipopcntx5fx(BC_N, iN.wrap_(BC_I)) = iN.wrap_(builtin.ipopcnt-bits(builtin.ibits-aux(BC_N, BC_I), 0))"
      ; "    if _>_(BC_N, 0)"
      ; "       /\\ _<_(BC_I, _^_(2, BC_N)) ."
      ]
    else
      [])
    @
    (if has_entry "inot_" then
       [ ""
       ; "  ceq definotx5fx(BT_N, iN.wrap_(BT_I)) = iN.wrap_(builtin.inv-ibits-aux(builtin.inot-bits(builtin.ibits-aux(BT_N, BT_I)), 0))"
       ; "    if _>_(BT_N, 0)"
       ; "       /\\ _<_(BT_I, _^_(2, BT_N)) ."
       ]
     else
       [])
    @
    (if has_entry "irev_" then
       [ ""
       ; "  ceq defirevx5fx(BT_N, iN.wrap_(BT_I)) = iN.wrap_(builtin.inv-ibits-aux(builtin.irev-bits(builtin.ibits-aux(BT_N, BT_I), eps), 0))"
       ; "    if _>_(BT_N, 0)"
       ; "       /\\ _<_(BT_I, _^_(2, BT_N)) ."
       ]
     else
       [])
    @
    (if has_entry "iand_" then
       [ ""
       ; "  ceq defiandx5fx(BT_N, iN.wrap_(BT_I), iN.wrap_(BT_J)) = iN.wrap_(builtin.inv-ibits-aux(builtin.iand-bits(builtin.ibits-aux(BT_N, BT_I), builtin.ibits-aux(BT_N, BT_J)), 0))"
       ; "    if _>_(BT_N, 0)"
       ; "       /\\ _<_(BT_I, _^_(2, BT_N))"
       ; "       /\\ _<_(BT_J, _^_(2, BT_N)) ."
       ]
     else
       [])
    @
    (if has_entry "iandnot_" then
       [ ""
       ; "  ceq defiandnotx5fx(BT_N, iN.wrap_(BT_I), iN.wrap_(BT_J)) = iN.wrap_(builtin.inv-ibits-aux(builtin.iandnot-bits(builtin.ibits-aux(BT_N, BT_I), builtin.ibits-aux(BT_N, BT_J)), 0))"
       ; "    if _>_(BT_N, 0)"
       ; "       /\\ _<_(BT_I, _^_(2, BT_N))"
       ; "       /\\ _<_(BT_J, _^_(2, BT_N)) ."
       ]
     else
       [])
    @
    (if has_entry "ior_" then
       [ ""
       ; "  ceq defiorx5fx(BT_N, iN.wrap_(BT_I), iN.wrap_(BT_J)) = iN.wrap_(builtin.inv-ibits-aux(builtin.ior-bits(builtin.ibits-aux(BT_N, BT_I), builtin.ibits-aux(BT_N, BT_J)), 0))"
       ; "    if _>_(BT_N, 0)"
       ; "       /\\ _<_(BT_I, _^_(2, BT_N))"
       ; "       /\\ _<_(BT_J, _^_(2, BT_N)) ."
       ]
     else
       [])
    @
    (if has_entry "ixor_" then
      [ ""
      ; "  ceq defixorx5fx(BT_N, iN.wrap_(BT_I), iN.wrap_(BT_J)) = iN.wrap_(builtin.inv-ibits-aux(builtin.ixor-bits(builtin.ibits-aux(BT_N, BT_I), builtin.ibits-aux(BT_N, BT_J)), 0))"
      ; "    if _>_(BT_N, 0)"
      ; "       /\\ _<_(BT_I, _^_(2, BT_N))"
      ; "       /\\ _<_(BT_J, _^_(2, BT_N)) ."
      ]
    else
      [])
    @
    (if has_entry "ibitselect_" then
      [ ""
      ; "  ceq defibitselectx5fx(BT_N, iN.wrap_(BT_I), iN.wrap_(BT_J), iN.wrap_(BT_K)) ="
      ; "      iN.wrap_(builtin.inv-ibits-aux("
      ; "        builtin.ior-bits("
      ; "          builtin.iand-bits(builtin.ibits-aux(BT_N, BT_I), builtin.ibits-aux(BT_N, BT_K)),"
      ; "          builtin.iand-bits(builtin.ibits-aux(BT_N, BT_J), builtin.inot-bits(builtin.ibits-aux(BT_N, BT_K)))),"
      ; "        0))"
      ; "    if _>_(BT_N, 0)"
      ; "       /\\ _<_(BT_I, _^_(2, BT_N))"
      ; "       /\\ _<_(BT_J, _^_(2, BT_N))"
      ; "       /\\ _<_(BT_K, _^_(2, BT_N)) ."
      ]
    else
      [])
    @
    (if has_entry "ishl_" then
       [ ""
       ; "  ceq defishlx5fx(SH_N, iN.wrap_(SH_I), u32.wrap_(SH_J)) ="
       ; "      iN.wrap_(_rem_(_*_(SH_I, _^_(2, SH_K)), _^_(2, SH_N)))"
       ; "    if _<_(SH_I, _^_(2, SH_N))"
       ; "       /\\ _<_(SH_J, _^_(2, 32))"
       ; "       /\\ SH_K := builtin.shift-count(SH_N, SH_J) ."
       ]
     else
       [])
    @
    (if has_entry "ishr_" then
       [ ""
       ; "  ceq defishrx5fx(SH_N, sx.u, iN.wrap_(SH_I), u32.wrap_(SH_J)) ="
       ; "      iN.wrap_(_quo_(SH_I, _^_(2, SH_K)))"
       ; "    if _<_(SH_I, _^_(2, SH_N))"
       ; "       /\\ _<_(SH_J, _^_(2, 32))"
       ; "       /\\ SH_K := builtin.shift-count(SH_N, SH_J) ."
       ; "  ceq defishrx5fx(SH_N, sx.s, iN.wrap_(SH_I), u32.wrap_(SH_J)) = iN.wrap_(SH_I)"
       ; "    if _<_(SH_I, _^_(2, SH_N))"
       ; "       /\\ _<_(SH_J, _^_(2, 32))"
       ; "       /\\ builtin.shift-count(SH_N, SH_J) = 0 ."
       ; "  ceq defishrx5fx(SH_N, sx.s, iN.wrap_(SH_I), u32.wrap_(SH_J)) ="
       ; "      iN.wrap_(builtin.sign-extend-nat(sd(SH_N, SH_K), SH_N, _quo_(SH_I, _^_(2, SH_K))))"
       ; "    if _<_(SH_I, _^_(2, SH_N))"
       ; "       /\\ _<_(SH_J, _^_(2, 32))"
       ; "       /\\ SH_K := builtin.shift-count(SH_N, SH_J)"
       ; "       /\\ _>_(SH_K, 0) ."
       ]
     else
       [])
    @
    (if has_entry "irotl_" then
       [ ""
       ; "  ceq defirotlx5fx(SH_N, iN.wrap_(SH_I), iN.wrap_(SH_J)) ="
       ; "      iN.wrap_(_rem_(_+_(_rem_(_*_(SH_I, _^_(2, SH_K)), _^_(2, SH_N)), _quo_(SH_I, _^_(2, sd(SH_N, SH_K)))), _^_(2, SH_N)))"
       ; "    if _<_(SH_I, _^_(2, SH_N))"
       ; "       /\\ _<_(SH_J, _^_(2, SH_N))"
       ; "       /\\ SH_K := builtin.shift-count(SH_N, SH_J) ."
       ]
     else
       [])
    @
    (if has_entry "irotr_" then
      [ ""
      ; "  ceq defirotrx5fx(SH_N, iN.wrap_(SH_I), iN.wrap_(SH_J)) ="
      ; "      iN.wrap_(_rem_(_+_(_quo_(SH_I, _^_(2, SH_K)), _*_( _rem_(SH_I, _^_(2, SH_K)), _^_(2, sd(SH_N, SH_K)))), _^_(2, SH_N)))"
      ; "    if _<_(SH_I, _^_(2, SH_N))"
      ; "       /\\ _<_(SH_J, _^_(2, SH_N))"
      ; "       /\\ SH_K := builtin.shift-count(SH_N, SH_J) ."
      ]
    else
      [])
    @
    (if has_entry "narrow__" then
      [ ""
      ; "  ceq defnarrowx5fxx5fx(NW_M, NW_N, sx.u, iN.wrap_(NW_I)) = iN.wrap_(NW_I)"
      ; "    if _>_(NW_M, NW_N)"
      ; "       /\\ _<_(NW_I, _^_(2, NW_N)) ."
      ; "  ceq defnarrowx5fxx5fx(NW_M, NW_N, sx.u, iN.wrap_(NW_I)) = iN.wrap_(sd(1, _^_(2, NW_N)))"
      ; "    if _>_(NW_M, NW_N)"
      ; "       /\\ _>=_(NW_I, _^_(2, NW_N))"
      ; "       /\\ _<_(NW_I, _^_(2, NW_M)) ."
      ; "  ceq defnarrowx5fxx5fx(NW_M, NW_N, sx.s, iN.wrap_(NW_I)) = iN.wrap_(NW_I)"
      ; "    if _>_(NW_M, NW_N)"
      ; "       /\\ _<_(NW_I, _^_(2, sd(1, NW_N))) ."
      ; "  ceq defnarrowx5fxx5fx(NW_M, NW_N, sx.s, iN.wrap_(NW_I)) = iN.wrap_(sd(1, _^_(2, sd(1, NW_N))))"
      ; "    if _>_(NW_M, NW_N)"
      ; "       /\\ _>=_(NW_I, _^_(2, sd(1, NW_N)))"
      ; "       /\\ _<_(NW_I, _^_(2, sd(1, NW_M))) ."
      ; "  ceq defnarrowx5fxx5fx(NW_M, NW_N, sx.s, iN.wrap_(NW_I)) = iN.wrap_(_^_(2, sd(1, NW_N)))"
      ; "    if _>_(NW_M, NW_N)"
      ; "       /\\ _>=_(NW_I, _^_(2, sd(1, NW_M)))"
      ; "       /\\ _<_(NW_I, sd(_^_(2, sd(1, NW_N)), _^_(2, NW_M))) ."
      ; "  ceq defnarrowx5fxx5fx(NW_M, NW_N, sx.s, iN.wrap_(NW_I)) = iN.wrap_(_+_(_-_(NW_I, _^_(2, NW_M)), _^_(2, NW_N)))"
      ; "    if _>_(NW_M, NW_N)"
      ; "       /\\ _>=_(NW_I, sd(_^_(2, sd(1, NW_N)), _^_(2, NW_M)))"
      ; "       /\\ _<_(NW_I, _^_(2, NW_M)) ."
      ]
    else
      [])
    @
    (if has_entry "iavgr_" then
      [ ""
      ; "  ceq defiavgrx5fx(AV_N, sx.u, iN.wrap_(AV_I), iN.wrap_(AV_J)) ="
      ; "      iN.wrap_(_quo_(_+_(_+_(AV_I, AV_J), 1), 2))"
      ; "    if _>_(AV_N, 0)"
      ; "       /\\ _<_(AV_I, _^_(2, AV_N))"
      ; "       /\\ _<_(AV_J, _^_(2, AV_N)) ."
      ]
    else
      [])
    @
    (if has_entry "iq15mulr_sat_" then
      [ ""
      ; "  ceq defiq15mulrx5fxsatx5fx(Q15_N, sx.s, iN.wrap_(Q15_I), iN.wrap_(Q15_J)) ="
      ; "      iN.wrap_(builtin.wrap-s-int(Q15_N,"
      ; "        builtin.sat-s-int(Q15_N,"
      ; "          builtin.floor-div-pow2-int("
      ; "            _+_(_*_(builtin.signed-nat(Q15_N, Q15_I), builtin.signed-nat(Q15_N, Q15_J)), 16384),"
      ; "            32768))))"
      ; "    if Q15_N = 16"
      ; "       /\\ _<_(Q15_I, _^_(2, Q15_N))"
      ; "       /\\ _<_(Q15_J, _^_(2, Q15_N)) ."
      ]
    else
      [])
    @
    (if has_entry "truncz" then
      [ ""
      ; "  ceq deftruncz(rat(TZ_R)) = floor(TZ_R)"
      ; "    if _>=_(TZ_R, 0) ."
      ; "  ceq deftruncz(rat(TZ_R)) = ceiling(TZ_R)"
      ; "    if _<_(TZ_R, 0) ."
      ]
    else
      [])
    @
    (if has_entry "ceilz" then
      [ ""
      ; "  eq defceilz(rat(TZ_R)) = ceiling(TZ_R) ."
      ]
    else
      [])
