(module
  (type $ret (func (result i32)))
  (table (export "tab") 1 funcref)
  (func $safe (type $ret) (result i32)
    i32.const 7)
  (func (export "call") (type $ret) (result i32)
    i32.const 0
    call_indirect (type $ret))
  (elem (i32.const 0) $safe)
)
