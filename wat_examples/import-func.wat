(module
  (type $imp_t (func (param i32) (result i32)))
  (import "env" "bump" (func $bump (type $imp_t)))
  (func $main (param i32) (result i32)
    local.get 0
    call $bump)
  (export "main" (func $main)))
