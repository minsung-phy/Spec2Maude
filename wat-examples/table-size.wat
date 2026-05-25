(module
  (table $tab (export "table") 3 funcref)
  (func $main (result i32)
    table.size $tab)
  (export "main" (func $main)))
