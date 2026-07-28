(module
  (func (export "value") (result v128)
    v128.const f32x4 nan -0 1 2))

(assert_return (invoke "value")
  (v128.const f32x4 nan:canonical 0 1 2))
