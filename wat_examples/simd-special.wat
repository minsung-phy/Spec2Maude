(module
  (memory 1)

  (func (param v128 v128) (result v128)
    local.get 0 local.get 1
    i8x16.shuffle 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)

  (func (param v128 v128) (result v128)
    local.get 0 local.get 1
    i8x16.narrow_i16x8_s)

  (func (param v128) (result v128)
    local.get 0
    i16x8.extend_low_i8x16_s)

  (func (param v128 v128) (result v128)
    local.get 0 local.get 1
    i16x8.extmul_low_i8x16_s)

  (func (param v128) (result v128)
    local.get 0
    i16x8.extadd_pairwise_i8x16_s)

  (func (param v128 v128) (result v128)
    local.get 0 local.get 1
    i32x4.dot_i16x8_s)

  (func (param v128) (result v128)
    local.get 0
    i32x4.trunc_sat_f32x4_s)

  (func (param i32) (result v128)
    local.get 0
    i8x16.splat)

  (func (param v128) (result i32)
    local.get 0
    i8x16.extract_lane_s 0)

  (func (param v128 i32) (result v128)
    local.get 0 local.get 1
    i8x16.replace_lane 0)

  (func (param i32) (result v128)
    local.get 0
    v128.load8x8_s)

  (func (param i32 v128) (result v128)
    local.get 0 local.get 1
    v128.load8_lane 0)

  (func (param i32 v128)
    local.get 0 local.get 1
    v128.store8_lane 0))
