(module
  (type $fib_t (func (param i32 i32 i32) (result i32)))
  (type $wrap_t (func (param i32 i32 i32) (result i32)))

  (func $fib (type $fib_t) (param i32 i32 i32) (result i32) (local i32)
    block
      loop
        local.get 0
        i32.const 0
        i32.le_s
        br_if 1
        local.get 1
        local.get 2
        i32.add
        local.set 3
        local.get 2
        local.set 1
        local.get 3
        local.set 2
        local.get 0
        i32.const 1
        i32.sub
        local.set 0
        br 0
      end
    end
    local.get 1)

  (func $wrapper (type $wrap_t) (param i32 i32 i32) (result i32)
    local.get 0
    local.get 1
    local.get 2
    call $fib)

  (export "fib" (func $fib))
  (export "wrapper" (func $wrapper)))
