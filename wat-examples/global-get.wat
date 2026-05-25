(module
  (global $g i32 (i32.const 41))
  (func $main (result i32)
    global.get $g
    i32.const 1
    i32.add)
  (export "main" (func $main))
  (export "g" (global $g)))
