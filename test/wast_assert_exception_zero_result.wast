(module
  (func (export "nothing")))

(assert_exception (invoke "nothing"))
