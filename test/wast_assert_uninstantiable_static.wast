(assert_trap
  (module
    (func (import "unknown" "f")))
  "unknown import")

(module $Provider
  (func (export "f")))
(register "provider" $Provider)

(assert_trap
  (module
    (global (import "provider" "f") i32))
  "incompatible import type")

(assert_trap
  (module
    (func (import "spectest" "print_i32") (param i32))
    (func (import "unknown" "f")))
  "unknown import after host allocation")
