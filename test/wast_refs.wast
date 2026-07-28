(module
  (func (export "is-null") (param externref) (result i32)
    local.get 0
    ref.is_null)
  (func (export "null") (result externref)
    ref.null extern)
  (func (export "identity") (param externref) (result externref)
    local.get 0))

(assert_return (invoke "is-null" (ref.null extern)) (i32.const 1))
(assert_return (invoke "is-null" (ref.extern 1)) (i32.const 0))
(assert_return (invoke "null") (ref.null extern))
(assert_return (invoke "identity" (ref.extern 2)) (ref.extern 2))
