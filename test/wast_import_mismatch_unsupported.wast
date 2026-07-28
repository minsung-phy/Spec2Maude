(module $Provider
  (func (export "f")))
(register "m" $Provider)
(module
  (func (import "m" "f") (param i32)))
