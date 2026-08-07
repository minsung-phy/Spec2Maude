(module
  (type $ret-i32 (func (result i32)))

  ;; This function is intentionally private.  Correct WebAssembly semantics
  ;; never place it in the table.
  (func $private-secret (type $ret-i32) (result i32)
    i32.const 1337)

  (table (export "table") 1 funcref)

  (func (export "call_slot") (type $ret-i32) (result i32)
    i32.const 0
    call_indirect (type $ret-i32))
)
