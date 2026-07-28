(assert_unlinkable
  (module
    (func $start unreachable)
    (start $start))
  "incompatible import type")
