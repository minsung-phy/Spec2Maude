(module
  (func (export "value") (result v128)
    v128.const f64x2 nan:0x8000000000001 1))

(assert_return (invoke "value")
  (v128.const f64x2 nan:canonical 1))
