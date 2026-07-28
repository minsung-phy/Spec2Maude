(module $MemoryGrower
  (memory (import "spectest" "memory") 1 2)
  (func (export "grow") (result i32)
    (memory.grow (i32.const 1))))
(assert_return (invoke $MemoryGrower "grow") (i32.const 1))

(module $MemoryReader
  (memory (import "spectest" "memory") 2 2)
  (func (export "size") (result i32) memory.size))
(assert_return (invoke $MemoryReader "size") (i32.const 2))

(module $TableGrower
  (table (import "spectest" "table") 10 20 funcref)
  (func (export "grow") (result i32)
    (table.grow (ref.null func) (i32.const 1))))
(assert_return (invoke $TableGrower "grow") (i32.const 10))

(module $TableReader
  (table (import "spectest" "table") 11 20 funcref)
  (func (export "size") (result i32) table.size))
(assert_return (invoke $TableReader "size") (i32.const 11))
