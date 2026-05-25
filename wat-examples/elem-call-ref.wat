(module
  (type $t (func (result i32)))
  (table $tab 1 funcref)
  (elem (i32.const 0) func $f)
  (func $f (type $t) (result i32)
    i32.const 9)
  (func $main (result i32)
    i32.const 0
    table.get $tab
    call_ref (type $t))
  (export "main" (func $main)))
