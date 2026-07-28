(module
  (func (export "one") (result i32)
    i32.const 1))

(assert_exhaustion (invoke "one") "call stack exhausted")
