(module $Before
  (global $value (import "spectest" "global_i32") i32)
  (func (export "read") (result i32)
    global.get $value))

(assert_return (invoke $Before "read") (i32.const 666))

(module $Override
  (global (export "global_i32") i32 (i32.const 42)))
(register "spectest" $Override)

(module $After
  (global $value (import "spectest" "global_i32") i32)
  (func (export "read") (result i32)
    global.get $value))

(assert_return (invoke $After "read") (i32.const 42))
