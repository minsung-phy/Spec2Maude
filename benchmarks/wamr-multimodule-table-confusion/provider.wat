(module
  (type $ret-i32 (func (result i32)))

  ;; Padding occupies provider-local function index 0.
  (func $padding (result i64)
    i64.const 0)

  ;; This private, unexported function occupies provider-local index 1.
  ;; Correct WebAssembly semantics never place it in the table.
  (func $private-secret (type $ret-i32) (result i32)
    i32.const 1337)

  (table (export "table") 1 funcref)

  (func (export "call_slot") (type $ret-i32) (result i32)
    i32.const 0
    call_indirect (type $ret-i32))
)
