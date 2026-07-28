(module $Writer
  (memory (import "spectest" "memory") 1 2)
  (func (export "write")
    i32.const 0
    i32.const 42
    i32.store8))

(module $Reader
  (memory (import "spectest" "memory") 1 2)
  (func (export "read") (result i32)
    i32.const 0
    i32.load8_u))

(invoke $Writer "write")
(assert_return (invoke $Reader "read") (i32.const 42))
