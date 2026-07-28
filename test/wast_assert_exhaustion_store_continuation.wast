(module
  (global $count (export "count") (mut i32) (i32.const 0))
  (func $recurse (export "recurse")
    global.get $count
    i32.const 1
    i32.add
    global.set $count
    call $recurse))

(assert_exhaustion (invoke "recurse") "call stack exhausted")
(assert_return (get "count") (i32.const 2))
