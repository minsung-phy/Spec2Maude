(module $Provider
  (memory (export "memory") 1 3))
(register "memory-provider" $Provider)

(assert_trap
  (module
    (memory (import "memory-provider" "memory") 2 3))
  "incompatible import type")
