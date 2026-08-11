(module
  (func $fib (export "fib")
    (param $n i32) (param $a i32) (param $b i32) (result i32)
    (local $next i32)
    block $done
      loop $again
        local.get $n
        i32.eqz
        br_if $done

        local.get $a
        local.get $b
        i32.add
        local.set $next

        local.get $b
        local.set $a
        local.get $next
        local.set $b

        local.get $n
        i32.const 1
        i32.sub
        local.set $n
        br $again
      end
    end
    local.get $a))
