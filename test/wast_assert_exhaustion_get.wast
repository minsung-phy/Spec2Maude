(module
  (global (export "value") i32 (i32.const 0)))

(assert_exhaustion
  (get "value")
  "call stack exhausted")

