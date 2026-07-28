(module
  (func (export "extern-id") (param externref) (result externref)
    local.get 0))

(assert_return (invoke "extern-id" (ref.extern 1)) (ref.null extern))
