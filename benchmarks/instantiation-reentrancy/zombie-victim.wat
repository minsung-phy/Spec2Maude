(module
  (type $slot (func (result i32)))

  (import "zombie-provider" "table" (table 1 funcref))

  (global $counter (mut i32) (i32.const 40))

  (func $zombie (type $slot) (result i32)
    global.get $counter
    i32.const 1
    i32.add
    global.set $counter
    global.get $counter)

  (elem (i32.const 0) $zombie)

  (func $start
    unreachable)

  (start $start))
