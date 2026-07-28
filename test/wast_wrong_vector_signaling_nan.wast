(module
  (func (export "value") (result v128)
    v128.const f32x4 nan:0x1 -nan:0x1 0 0))

(assert_return (invoke "value")
  (v128.const f32x4 nan:arithmetic nan:arithmetic 0 0))
