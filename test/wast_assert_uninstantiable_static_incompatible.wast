(module $Provider
  (func (export "f")))
(register "provider" $Provider)

(assert_trap
  (module
    (global (import "provider" "f") i32))
  "incompatible import type")
