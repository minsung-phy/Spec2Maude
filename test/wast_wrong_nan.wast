(module
  (func (export "noncanonical") (result f32)
    f32.const nan:0x400001))

(assert_return (invoke "noncanonical") (f32.const nan:canonical))
