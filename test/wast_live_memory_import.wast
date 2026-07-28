(module $Provider
  (memory (export "memory") 1 3)
  (func (export "grow") (result i32)
    (memory.grow (i32.const 1)))
  (func (export "read") (result i32)
    (i32.load8_u (i32.const 0))))
(register "grown-memory" $Provider)
(assert_return (invoke $Provider "grow") (i32.const 1))

(module $Consumer
  (memory (import "grown-memory" "memory") 2 3)
  (func (export "size") (result i32) memory.size)
  (func (export "write")
    (i32.store8 (i32.const 0) (i32.const 42))))
(assert_return (invoke $Consumer "size") (i32.const 2))
(invoke $Consumer "write")
(assert_return (invoke $Provider "read") (i32.const 42))
