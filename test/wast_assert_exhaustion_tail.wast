(module
  (func $tail (export "tail")
    return_call $tail))

(assert_exhaustion (invoke "tail") "call stack exhausted")

