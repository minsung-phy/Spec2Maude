(module
  (global (export "value") i32 (i32.const 1)))

(assert_exception (get "value"))
