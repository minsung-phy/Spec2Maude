(module
  (func (export "identity") (param v128) (result v128)
    local.get 0))

(assert_return
  (invoke "identity"
    (v128.const i8x16 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15))
  (v128.const i8x16 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15))

(assert_return
  (invoke "identity"
    (v128.const i16x8 0 257 514 771 -1 -2 32767 -32768))
  (v128.const i16x8 0 257 514 771 -1 -2 32767 -32768))

(assert_return
  (invoke "identity"
    (v128.const i32x4 1 -2 2147483647 -2147483648))
  (v128.const i32x4 1 -2 2147483647 -2147483648))

(assert_return
  (invoke "identity"
    (v128.const i64x2 9223372036854775807 -9223372036854775808))
  (v128.const i64x2 9223372036854775807 -9223372036854775808))

(assert_return
  (invoke "identity" (v128.const f32x4 1 -2 3.5 -4.25))
  (v128.const f32x4 1 -2 3.5 -4.25))

(assert_return
  (invoke "identity" (v128.const f64x2 1.5 -2.25))
  (v128.const f64x2 1.5 -2.25))

(invoke "identity" (v128.const i32x4 1 2 3 4))
