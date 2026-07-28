(module $Provider
  (func (export "f")))
(register "m" $Provider)
(assert_unlinkable
  (module
    (func (import "m" "missing")))
  "unknown import")
