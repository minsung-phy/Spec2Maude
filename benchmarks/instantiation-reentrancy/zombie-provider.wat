(module
  (type $slot (func (result i32)))

  (table (export "table") 1 funcref)

  (func (export "call_slot") (result i32)
    i32.const 0
    call_indirect (type $slot)))
