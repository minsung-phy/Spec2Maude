(module $Provider
  (memory (export "memory") 1 3)
  (table (export "table") 1 3 funcref))
(register "resources" $Provider)

(assert_unlinkable
  (module
    (memory (import "resources" "memory") 2 3)
    (table (import "resources" "table") 2 3 funcref))
  "incompatible import type")
