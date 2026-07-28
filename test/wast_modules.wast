(module
  (func (export "value") (result i32)
    i32.const 1))

(assert_return (invoke "value") (i32.const 1))

(module
  (func (export "value") (result i32)
    i32.const 2))

(assert_return (invoke "value") (i32.const 2))
