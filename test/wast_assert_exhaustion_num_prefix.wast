(module
  (func $recurse (export "recurse")
    i32.const 7
    call $recurse
    drop))

(assert_exhaustion (invoke "recurse") "call stack exhausted")
