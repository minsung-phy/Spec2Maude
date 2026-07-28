(assert_trap
  (module
    (tag $exception)
    (func $start (throw $exception))
    (start $start))
  "uncaught exception")
