(module
  (func (export "trap") unreachable))

(assert_exception (invoke "trap"))
