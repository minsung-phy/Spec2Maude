(module
  (func $recurse (export "recurse")
    ref.null extern
    call $recurse
    drop))

(assert_exhaustion (invoke "recurse") "call stack exhausted")
