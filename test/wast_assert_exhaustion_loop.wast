(module
  (func (export "loop")
    loop $again
      br $again
    end))

(assert_exhaustion (invoke "loop") "call stack exhausted")

