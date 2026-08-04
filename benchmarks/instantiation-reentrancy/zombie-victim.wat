(module
  (type $slot (func (result i32)))

  (import "zombie-provider" "table" (table 1 funcref))

  (func $zombie (type $slot) (result i32)
    i32.const 42)

  (elem (i32.const 0) $zombie)

  (func $start
    unreachable)

  (start $start))
