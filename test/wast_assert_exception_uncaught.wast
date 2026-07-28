(module
  (tag $e)
  (func (export "throw") (throw $e))
  (func (export "one") (result i32) (i32.const 1)))

(assert_exception (invoke "throw"))
(assert_return (invoke "one") (i32.const 1))
