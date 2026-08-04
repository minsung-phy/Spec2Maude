;; Two pure core-Wasm lifecycle witnesses.
;;
;; 1. Construction reentrancy:
;;    The provider owns a table and a hook. The victim imports both. During
;;    victim instantiation, its active element segment places $leaked into the
;;    already-existing provider table before the victim start function runs.
;;    The start function then calls provider.hook. provider.hook calls table[0],
;;    re-entering the victim before its $ready global is set to 1.
;;
;; 2. Failed-instantiation zombie capability:
;;    A second victim publishes a function into another imported table and then
;;    traps in its start function. Instantiation fails, but the table entry is
;;    not rolled back, so the provider can still execute code allocated for the
;;    failed module.

(module $provider
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

(register "provider" $provider)

(module $victim
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

;; During start, provider.hook observed victim.ready == 0.
(assert_return (get $provider "observed") (i32.const 0))
(assert_return (invoke $provider "get_observed") (i32.const 0))

;; After start returns, the same leaked function observes ready == 1.
(assert_return (invoke $provider "call_slot") (i32.const 1))

(module $zombie-provider
  (type $slot (func (result i32)))

  (table (export "table") 1 funcref)

  (func (export "call_slot") (result i32)
    i32.const 0
    call_indirect (type $slot)))

(register "zombie-provider" $zombie-provider)

(assert_trap
  (module $zombie-victim
    (type $slot (func (result i32)))

    (import "zombie-provider" "table" (table 1 funcref))

    (func $zombie (type $slot) (result i32)
      i32.const 42)

    ;; This mutates the already-live imported table before start executes.
    (elem (i32.const 0) $zombie)

    (func $start
      unreachable)

    (start $start))
  "unreachable")

;; The failed module has no instance binding, yet its function remains callable.
(assert_return (invoke $zombie-provider "call_slot") (i32.const 42))
