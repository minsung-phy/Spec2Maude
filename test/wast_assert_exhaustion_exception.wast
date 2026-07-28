(module
  (tag $e)
  (func (export "throw") (throw $e)))

(assert_exhaustion (invoke "throw") "call stack exhausted")

