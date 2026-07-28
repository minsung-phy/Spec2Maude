(module
  (func (export "signaling") (result f32)
    f32.const nan:0x1))

(assert_return (invoke "signaling") (f32.const nan:arithmetic))
