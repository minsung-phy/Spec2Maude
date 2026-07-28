(module
  (global $value (import "spectest" "global_i32") i32)
  (func (export "read") (result i32)
    global.get $value))

(assert_return (invoke "read") (i32.const 666))
