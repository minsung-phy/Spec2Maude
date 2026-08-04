(module
  (type $slot (func (result i32)))

  (table (export "table") 1 funcref)
  (global $observed (mut i32) (i32.const -1))
  (export "observed" (global $observed))

  (func (export "hook")
    i32.const 0
    call_indirect (type $slot)
    global.set $observed)

  (func (export "call_slot") (result i32)
    i32.const 0
    call_indirect (type $slot))

  (func (export "get_observed") (result i32)
    global.get $observed))
