(module
  (type $ret-i64 (func (result i64)))
  (type $ret-i32 (func (result i32)))

  (import "provider" "table" (table 1 funcref))
  ;; This function import occupies consumer-local function index 0.
  (import "provider" "call_slot"
    (func $provider-call-slot (type $ret-i32)))

  ;; This consumer function therefore occupies consumer-local index 1 and has
  ;; the wrong dynamic type for provider.call_slot's () -> i32 expectation.
  (func $poison (type $ret-i64) (result i64)
    i64.const 0)

  ;; Correct semantics stores a reference to consumer.$poison.  A runtime must
  ;; not reinterpret the bare consumer-local integer 1 in the provider's index
  ;; space.
  (elem (i32.const 0) func $poison)

  (func (export "trigger") (type $ret-i32) (result i32)
    call $provider-call-slot)
)
