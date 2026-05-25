(module
  (import "env" "g" (global $g i32))
  (func $main (result i32)
    global.get $g)
  (export "main" (func $main)))
