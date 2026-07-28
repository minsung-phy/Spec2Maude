(assert_unlinkable
  (module
    (func (import "unknown" "f")))
  "unknown import")

(module $Provider
  (func (export "f"))
  (global (export "g") i32 (i32.const 0)))
(register "m" $Provider)

(assert_unlinkable
  (module
    (func (import "m" "missing")))
  "unknown import")

(assert_unlinkable
  (module
    (global (import "m" "f") i32))
  "incompatible import type")

(assert_unlinkable
  (module
    (func (import "spectest" "print"))
    (func (import "unknown" "f")))
  "unknown import")

(assert_unlinkable
  (module
    (func (import "spectest" "missing")))
  "unknown import")

(assert_unlinkable
  (module
    (func (import "m" "f") (param i32)))
  "incompatible import type")

(assert_unlinkable
  (module
    (global (import "m" "g") (mut i32)))
  "incompatible import type")

(assert_unlinkable
  (module
    (func (import "spectest" "print_i32") (param i32))
    (func (import "unknown" "f")))
  "unknown import")
