(module
  (type $ret (func (result i32)))
  (import "provider" "tab" (table 1 funcref))
  (func $evil (type $ret) (result i32)
    i32.const 99)
  (elem (i32.const 0) $evil)
)
