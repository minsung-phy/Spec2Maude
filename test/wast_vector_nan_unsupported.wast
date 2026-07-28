(module
  (func (export "zero") (result v128)
    v128.const f32x4 0 0 0 0))

(assert_return
  (invoke "zero")
  (v128.const f32x4 nan:canonical 0 0 0))
