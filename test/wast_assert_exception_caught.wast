(module
  (tag $e)
  (func (export "caught") (result i32)
    (block $handler
      (try_table (catch $e $handler)
        (throw $e)))
    (i32.const 7)))

(assert_exception (invoke "caught"))
