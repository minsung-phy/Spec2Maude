(module
  ;; A minimal Wasm chat-client guard.
  ;; The client accepts an incoming message only when its sequence number
  ;; equals the sequence number currently expected by the local log.
  (func (export "accept") (param $expected i32) (param $incoming i32) (result i32)
    local.get $incoming
    local.get $expected
    i32.eq))
