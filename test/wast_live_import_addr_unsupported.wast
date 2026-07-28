(module $Provider
  (memory (export "memory") 1 3))
(register "memory32" $Provider)

(module
  (memory (import "memory32" "memory") i64 2 3))
