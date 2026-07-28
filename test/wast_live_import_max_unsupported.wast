(module $Provider
  (memory (export "memory") 1 3))
(register "memory-max" $Provider)

(module
  (memory (import "memory-max" "memory") 2 2))
