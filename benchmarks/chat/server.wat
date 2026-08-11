(module
  (func (export "buggy")
    (param $active i32)
    (param $current-epoch i32)
    (param $message-epoch i32)
    (param $last-sequence i32)
    (param $message-sequence i32)
    (result i32)
    local.get $current-epoch
    local.get $message-epoch
    i32.eq
    local.get $last-sequence
    local.get $message-sequence
    i32.ne
    i32.and)

  (func (export "fixed")
    (param $active i32)
    (param $current-epoch i32)
    (param $message-epoch i32)
    (param $last-sequence i32)
    (param $message-sequence i32)
    (result i32)
    local.get $active
    i32.const 0
    i32.ne
    local.get $current-epoch
    local.get $message-epoch
    i32.eq
    i32.and
    local.get $last-sequence
    local.get $message-sequence
    i32.ne
    i32.and))
