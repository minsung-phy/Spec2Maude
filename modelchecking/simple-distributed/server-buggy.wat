;; Server가 지금까지 요청을 처리한 횟수를 count라고 하자
;; 요청 하나 받으면 count -> count + 1

(module
    (func (export "server_step")
          (param $count i32)
          (result i32)
        local.get $count
        i32.const 1
        i32.add
    )
)

;; 왜 이게 buggy인가?
;;; 첫 request: server_step(0) = 1
;;; 똑같은 request가 retry되어 또 옴: server_step(1) = 2
;;; -> 서버가 "이 request는 아까 처리했던 거다"를 전혀 확인하지 않기에 buggy임 !