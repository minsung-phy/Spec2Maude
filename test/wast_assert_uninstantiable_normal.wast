(assert_trap
  (module
    (func $start)
    (start $start))
  "unreachable")
