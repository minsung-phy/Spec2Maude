(module
  (func (export "shl") (param i64 i64) (result i64)
    local.get 0
    local.get 1
    i64.shl))

(assert_return (invoke "shl" (i64.const 1) (i64.const 64))
  (i64.const 1))
(assert_return (invoke "shl" (i64.const 1) (i64.const 65))
  (i64.const 2))
(assert_return (invoke "shl" (i64.const 1) (i64.const -1))
  (i64.const 0x8000000000000000))
