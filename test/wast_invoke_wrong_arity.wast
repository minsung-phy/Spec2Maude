(module
  (func (export "id") (param i32) (result i32)
    local.get 0))

(assert_return (invoke "id") (i32.const 0))
