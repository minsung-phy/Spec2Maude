(module
  (type $t (func (result i32)))
  (func $f (type $t) (result i32)
    i32.const 9)
  (elem declare func $f)
  (func $main (result i32)
    ref.func $f
    call_ref $t)
  (export "main" (func $main)))
