(module
  (func (export "three") (result i32) i32.const 3))

(assert_return (invoke "three")
  (either (i32.const 1) (i32.const 2)))
