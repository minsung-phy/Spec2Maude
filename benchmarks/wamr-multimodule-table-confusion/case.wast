;; Cross-module table identity oracle.
;;
;; The consumer writes a reference to its own () -> i64 function into the
;; provider's imported funcref table.  The provider later performs call_indirect
;; expecting () -> i32.  Correct WebAssembly semantics must dynamically inspect
;; the referenced consumer function and trap on the type mismatch.  The
;; provider's private function at its own numeric index 0 is never stored.

(module $provider
  (type $ret-i32 (func (result i32)))

  (func $private-secret (type $ret-i32) (result i32)
    i32.const 1337)

  (table (export "table") 1 funcref)

  (func (export "call_slot") (type $ret-i32) (result i32)
    i32.const 0
    call_indirect (type $ret-i32)))

(register "provider" $provider)

(module $consumer
  (type $ret-i64 (func (result i64)))

  (import "provider" "table" (table 1 funcref))

  (func $poison (type $ret-i64) (result i64)
    i64.const 0)

  (elem (i32.const 0) $poison)

  (func (export "ready") (result i32)
    i32.const 1))

(assert_return (invoke $consumer "ready") (i32.const 1))
(assert_trap (invoke $provider "call_slot") "indirect call type mismatch")
