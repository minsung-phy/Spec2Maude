(module
  (memory $mem (export "memory") 0)
  (func $main (result i32)
    memory.size)
  (export "main" (func $main)))
