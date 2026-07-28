(module
  (func (export "values") (result i32 i64)
    i32.const 1
    i64.const 2))

(assert_exhaustion (invoke "values") "call stack exhausted")

