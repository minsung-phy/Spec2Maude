(module
  (func $recurse (export "finite") (param i32)
    local.get 0
    i32.eqz
    if
      return
    end
    local.get 0
    i32.const 1
    i32.sub
    call $recurse))

(assert_exhaustion
  (invoke "finite" (i32.const 1))
  "call stack exhausted")

