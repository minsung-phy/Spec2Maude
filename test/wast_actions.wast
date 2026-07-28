(module
  (global (export "value") (mut i32) (i32.const 1))
  (func (export "set")
    i32.const 2
    global.set 0))

(invoke "set")
(assert_return (get "value") (i32.const 2))
