(module
  (func (export "fib") (param i64) (result i64)
    local.get 0 i64.const 1 i64.le_u
    if (result i64)
      i64.const 1
    else
      local.get 0 i64.const 2 i64.sub call 0
      local.get 0 i64.const 1 i64.sub call 0
      i64.add
    end))
