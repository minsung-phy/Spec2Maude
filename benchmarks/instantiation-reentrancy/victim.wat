(module
  (type $slot (func (result i32)))

  (import "provider" "table" (table 1 funcref))
  (import "provider" "hook" (func $hook))

  (global $ready (mut i32) (i32.const 0))

  (func $leaked (type $slot) (result i32)
    global.get $ready)

  (elem (i32.const 0) $leaked)

  (func $start
    call $hook
    i32.const 1
    global.set $ready)

  (start $start))
