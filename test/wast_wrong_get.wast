(module
  (global (export "seven") i32 (i32.const 7)))

(assert_return (get "seven") (i32.const 8))
