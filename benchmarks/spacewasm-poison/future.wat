(module
  (type $ret (func (result i32)))
  ;; Deliberately not exported. A rejected earlier module must not be able to
  ;; make this future module's private function callable from the provider.
  (func $private-future (type $ret) (result i32)
    i32.const 31337)
)
