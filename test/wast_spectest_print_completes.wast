(module
  (func $print (import "spectest" "print_i32") (param i32))
  (func (export "run")
    i32.const 7
    call $print))

(invoke "run")
