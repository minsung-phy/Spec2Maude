(module $Provider
  (memory (export "memory") 1)
  (func (export "read") (result i32)
    (i32.load8_u (i32.const 0))))
(register "memory-provider" $Provider)

(module definition $Fail
  (memory (import "memory-provider" "memory") 1)
  (func $start
    (i32.store8 (i32.const 0) (i32.const 42))
    unreachable)
  (start $start))

(assert_trap (module instance $Fail) "unreachable")
(assert_return (invoke $Provider "read") (i32.const 42))

(module $After
  (func (export "value") (result i32) (i32.const 7)))
(assert_return (invoke $After "value") (i32.const 7))
