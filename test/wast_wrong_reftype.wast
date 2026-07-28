(module
  (func $target)
  (func (export "function") (result funcref) ref.func $target)
  (elem declare func $target))

(assert_return (invoke "function") (ref))
