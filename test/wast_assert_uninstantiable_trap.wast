(module definition $Fail
  (func $start unreachable)
  (start $start))

(assert_trap (module instance $Fail) "expected-source-message")

(module $After
  (func (export "value") (result i32) (i32.const 7)))
(assert_return (invoke $After "value") (i32.const 7))
