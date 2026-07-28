(module
  (func (export "eqz") (param i32) (result i32)
    local.get 0
    i32.eqz))

(assert_return (invoke "eqz" (i32.const 0)) (i32.const 1))
(assert_return (invoke "eqz" (i32.const 1)) (i32.const 0))
