(module definition $Provider
  (global $g (export "g") (mut i32) (i32.const 0))
  (func (export "set") (param i32)
    local.get 0
    global.set $g)
  (func (export "get") (result i32)
    global.get $g))

(module instance $first $Provider)
(module instance $second $Provider)
(register "m" $first)

(module definition $Consumer
  (global $g (import "m" "g") (mut i32))
  (func $set (import "m" "set") (param i32))
  (func $get (import "m" "get") (result i32))
  (func (export "read") (result i32)
    call $get)
  (func (export "read-global") (result i32)
    global.get $g)
  (func (export "write") (param i32)
    local.get 0
    call $set))

(module instance $consumer-1 $Consumer)
(module instance $consumer-2 $Consumer)
(register "m" $second)
(module instance $consumer-3 $Consumer)

(invoke $consumer-1 "write" (i32.const 11))
(assert_return (invoke $consumer-2 "read") (i32.const 11))
(assert_return (invoke $consumer-2 "read-global") (i32.const 11))
(assert_return (invoke $consumer-3 "read") (i32.const 0))

(invoke $consumer-3 "write" (i32.const 22))
(assert_return (invoke $first "get") (i32.const 11))
(assert_return (invoke $second "get") (i32.const 22))
