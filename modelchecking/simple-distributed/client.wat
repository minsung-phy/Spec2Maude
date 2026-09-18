(module ;; Wasm 프로그램 하나 시작한다는 뜻
    (func (export "client_step") ;; client_step이라는 함수를 하나 만든다는 뜻 / export가 붙었으니까 밖에서 이 함수를 호출할 수 있음
                                    ;; 현재 state와 event를 받아서 새로운 state를 숫자로 반환하는 함수임
          (param $state i32) ;; 첫 번째 입력값 - state = client가 지금 어떤 상태인지를 나타내고 타입은 i32
                                ;; 0 = 요청 전, 1 = ACK 기다리는 중, 2 = 완료
          (param $event i32) ;; 두 번째 입력값 - event = client에게 무슨 일이 일어났는지를 나타냄
                                ;; 0 = 시작, 1 = ACK 도착, 2 = timeout
          (result i32) ;; 이 함수의 결과도 i32
        
        ;; state == 0 : 아직 요청 전
        local.get $state ;; 함수 인자로 받은 state 값을 stack 위에 올려라
        i32.const 0 ;; stack에 0을 하나 더 올림
        i32.eq ;; $state == 0 ? -> 참이면 1, 거짓이면 0을 stack에 올림

        if (result i32) ;; stack 위 값이 1이면 then, 0이면 else / (result i32)는 if문이 끝났을 때 i32 값 하나를 결과로 남기겠다라는 뜻
            ;; START이면 WAITING(1)으로
            local.get $event
            i32.const 0
            i32.eq

            if (result i32)  
                i32.const 1 
            else 
                i32.const 0
            end

        else
            ;; state == 1 : ACK 기다리는 중
            local.get $state
            i32.const 1
            i32.eq

            if (result i32)
                ;; ACK이면 DONE(2)
                local.get $event
                i32.const 1
                i32.eq

                if (result i32)
                    i32.const 2   
                else
                    ;; TIMEOUT 등: 계속 WAITING
                    i32.const 1
                end
            else
                ;; state == 2 : 이미 완료
                i32.const 2
            end
        end
    )
)