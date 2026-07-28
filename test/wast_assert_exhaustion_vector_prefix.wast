(module
  (func $recurse (export "recurse")
    v128.const i32x4 1 2 3 4
    call $recurse
    drop))

(assert_exhaustion (invoke "recurse") "call stack exhausted")
