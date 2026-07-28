(module $Provider
  (memory (export "memory") 1 3)
  (table (export "table") 1 3 funcref)
  (func (export "grow-memory") (result i32)
    (memory.grow (i32.const 1)))
  (func (export "grow-table") (result i32)
    (table.grow (ref.null func) (i32.const 1))))
(register "resources" $Provider)

(assert_unlinkable
  (module
    (memory (import "resources" "memory") 2 3)
    (table (import "resources" "table") 2 3 funcref))
  "incompatible import type")

(invoke $Provider "grow-memory")
(invoke $Provider "grow-table")

(assert_unlinkable
  (module
    (memory (import "resources" "memory") 2 3)
    (table (import "resources" "table") 2 3 funcref))
  "incompatible import type")
