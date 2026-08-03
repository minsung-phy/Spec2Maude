(module
  (func (export "id") (param i32) (result i32)
    local.get 0))

(assert_return (invoke "id" (i64.const 0)) (i32.const 0))
