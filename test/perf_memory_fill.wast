(module
  (memory 1)
  (func (export "fill") (param i32)
    i32.const 0
    i32.const 1
    local.get 0
    memory.fill))

(assert_return (invoke "fill" (i32.const 8)))
