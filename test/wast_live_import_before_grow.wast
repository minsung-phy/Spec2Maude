(module $Provider
  (memory (export "memory") 1 3))
(register "ungrown-memory" $Provider)

(module
  (memory (import "ungrown-memory" "memory") 2 3))
