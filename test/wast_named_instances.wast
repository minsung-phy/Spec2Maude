(module definition $Counter
  (global $value (export "value") (mut i32) (i32.const 0))
  (func (export "inc")
    global.get $value
    i32.const 1
    i32.add
    global.set $value)
  (func (export "read") (result i32)
    global.get $value))

(module instance $left $Counter)
(module instance $right $Counter)

(invoke $left "inc")
(assert_return (get $left "value") (i32.const 1))
(assert_return (get $right "value") (i32.const 0))

(invoke "inc")
(assert_return (get "value") (i32.const 1))
(assert_return (invoke $left "read") (i32.const 1))
