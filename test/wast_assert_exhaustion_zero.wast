(module
  (func (export "nothing")))

(assert_exhaustion (invoke "nothing") "call stack exhausted")

