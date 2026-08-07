(module
  (type $ret-i64 (func (result i64)))

  (import "provider" "table" (table 1 funcref))

  ;; This is function index 0 in the consumer, but it has the wrong dynamic
  ;; type for provider.call_slot's expected () -> i32 signature.
  (func $poison (type $ret-i64) (result i64)
    i64.const 0)

  ;; Correct semantics stores a reference to consumer.$poison, not the bare
  ;; integer 0.  Therefore provider.call_slot must trap on a type mismatch.
  (elem (i32.const 0) func $poison)

  (func (export "ready") (result i32)
    i32.const 1)
)
