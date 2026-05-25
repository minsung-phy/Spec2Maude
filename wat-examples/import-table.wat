(module
  (import "env" "tab" (table $tab 4 funcref))
  (func $main (result i32)
    table.size $tab)
  (export "main" (func $main)))
