(module
  (import "env" "mem" (memory $mem 1))
  (func $main (result i32)
    memory.size)
  (export "main" (func $main)))
