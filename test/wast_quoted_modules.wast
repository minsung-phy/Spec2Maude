(module quote
  "(@a) (func (export \"seven\") (result i32) i32.const 7)")

(assert_return (invoke "seven") (i32.const 7))

(module definition $Quoted quote
  "(func (export \"nine\") (result i32) i32.const 9)")
(module instance $quoted $Quoted)

(assert_return (invoke $quoted "nine") (i32.const 9))
