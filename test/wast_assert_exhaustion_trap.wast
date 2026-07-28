(module
  (func (export "trap") unreachable))

(assert_exhaustion (invoke "trap") "call stack exhausted")

