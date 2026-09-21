# LTL Model Checking a simple Client-Server Syetem

## 1. System: 요청을 재전송하는 client와 server
- 정상적인 경우
  1. browser(client.wasm) 결제 요청
  2. server(server.wasm)이 결제 처리(count =+ 1) 이후 ACK 전송
  3. browser(client.wasm)은 ACK를 받고 Done
  정상적인 경우에는 서버가 결제를 한 번 처리하고 client는 ACK를 받아서 끝냄
- 비정상적인 경우
  1. browser(client.wasm) 결제 요청
  2. server(server.wasm)이 결제 처리(count =+ 1) 이후 ACK 전송 -> But ACK 유실
  3. browser(client.wasm)은 ACK를 못받음
  이때 client 입장에서는 문제가 발생함 -> ACK가 안왔는데 "server가 요청을 못 받은건지 아니면 처리했는데 ACK만 없어진건지 알 수 없음"
  그래서 일정 시간이 지나면 같은 요청을 재전송함
  만약 server가 요청을 못 받은게 아니라 ACK가 유실된거라면 "사용자는 1번 결제했는데 server에서는 2번 처리됨"

## 2. 이 예제를 선택한 이유
각 프로그램 자체는 single threaded임 
- client.wasm: single thread
- server.wasm: single thread
그리고 둘은 메모리를 공유하지 않음. 오직 message 통신임.

-> 즉 교수님이 말씀하신 "distributed wasm application을 모델체킹"임

전체 system에서는 non-determinism도 자연스럽게 생김
서버가 ACK를 보냈을 때:
- ACK 전달 -> client 종료
- ACK 유실 -> client timeout -> 재전송
따라서 동일한 initial state에서 여러 실행 경로가 생김 -> Model Checking 가능 !!

## 3. client.wat & server-buggy.wat
**[client.wat](./client.wat)**

client.wat 보기 편한 version:
```
func client_step(i32 state, i32 event) -> i32 :
    if (state == 0) :
        if (event == 0) : return 1
        else : return 0
    else :
        if (state == 1) :
            if (event == 1) : return 2
            else : return 1
        else : return 2
```

```
State: 0 - 아직 요청 안보냄
       1 - 요청을 보냈고 ACK 기다리는 중
       2 - ACK 받아서 완료됨
Event: 0 - Client 요청 시작
       1 - ACK 받음
       2 - ACK 못 받음
```
| 현재 State | Event | 다음 State |
|---|---|---|
| 0 요청 전 | 0 START | 1 WAITING |
| 0 요청 전 | 그 외 | 0 요청 전 |
| 1 WAITING | 1 ACK | 2 DONE |
| 1 WAITING | 2 TIMEOUT | 1 WAITING |
| 2 DONE | 그 외 | 2 DONE |

**[server-buggy.wat](./server-buggy.wat)**

server-buggy.wat 보기 편한 version:
```
func server_step(i32 count) -> i32 :
    count =+ 1
```

## 4. .wasm으로 컴파일
```
wat2wasm client.wat -o client.wasm
wat2wasm server-buggy.wat -o server-buggy.wasm
```

validation: .wasm 파일이 WebAssembly 규칙상 올바른 프로그램인지 검사
```
wasm-validate client.wasm
wasm-validate server-buggy.wasm
```

## 5. wasm2maude로 Maude 실행 파일 생성 후 output.maude 위에서 실제 실행
```
dune exec bin/wasm2maude.exe -- run \
  modelchecking/simple-distributed/client.wasm \
  --invoke client_step \
  --arg i32:1 \
  --arg i32:2 \
  --steps 1000 \
  -o modelchecking/simple-distributed/client-timeout.maude

maude modelchecking/simple-distributed/client-timeout.maude
```

```
dune exec bin/wasm2maude.exe -- run \
  modelchecking/simple-distributed/server-buggy.wasm \
  --invoke server_step \
  --arg i32:0 \
  --steps 1000 \
  -o modelchecking/simple-distributed/server-0.maude

maude modelchecking/simple-distributed/server-0.maude
```

## 6. Client + Server + Network를 하나의 분산 시스템으로 구성

`run`은 고정 인자로 한 번 실행하는 파일을 만든다. 분산 모델에서 인자를
전달하고 반환값을 받으려면 `harness`로 두 모듈을 생성한다.
저장소 루트에서 실행하며, 생성 파일을 수동 수정할 필요가 없다.

```sh
dune exec bin/wasm2maude.exe -- harness \
  modelchecking/simple-distributed/client.wasm --invoke client_step \
  --module-name CLIENT-WASM --prefix client \
  -o modelchecking/simple-distributed/client.maude
dune exec bin/wasm2maude.exe -- harness \
  modelchecking/simple-distributed/server-buggy.wasm --invoke server_step \
  --module-name SERVER-BUGGY-WASM --prefix server \
  -o modelchecking/simple-distributed/server-buggy.maude
maude modelchecking/simple-distributed/distributed-system.maude
```

`distributed-system.maude`가 의미론을 먼저 로드하고 두 모듈을 불러온다.
`clientCall(ARGS)`에서 `clientResult(RESULT)`까지, 그리고
`serverCall(ARGS)`에서 `serverResult(RESULT)`까지의 실행을 프로토콜 규칙이 사용한다.
각 호출은 새 인스턴스를 생성한다. 현재 두 함수는 상태를 숫자 인자로 주고받으므로
이 계약에 맞지만, 메모리·전역변수를 호출 사이에 보존하는 프로그램에는 별도 모델이 필요하다.

호출 전체는 프로토콜 전이 하나의 조건으로 실행되어 Wasm 내부 단계가 네트워크와
교차하지 않는다. 또한 서버의 `2+` 포화는 i32 overflow까지 보존하는 정확한 축약은
아니다. 짧은 중복 처리 반례는 포화 전에 발생한다. Fairness가 붙은 liveness는
해당 전달 공정성을 가정한 유한 프로토콜 모델의 결과다.

앞 단계까지는 client.wasm과 server-buggy.wasm을 각각 따로 실행했음

이제 두 프로그램을 Network를 통해 연결하여 하나의 시스템으로 구성하자 !

전체 시스템 상태는 다음 세 정보로 표현하자 
SystemState = Client의 상태 + Server의 처리 횟수 + Network에 존재하는 메시지
ex) < 1, 1, ack >는 다음을 의미한다
    Client = 1 (요청을 보냈고 ACK를 기다리는 중)
    Server = 1 (요청을 한 번 처리함)
    Network = ack (Server가 보낸 ACK가 아직 Client에게 전달되지 않음)
Network에는 세 상태만 사용한다
- none = 전달 중인 메시지 없음
- req = Client -> Server 요청
- ack = Server -> Client 응답

가능한 시스템 동작:
```
1. Client가 요청 시작
   -> Network에 req 생성

2. req가 Server에 전달
   -> Server count 증가
   -> Network에 ack 생성

3. req가 유실
   -> Network에서 req 제거

4. ack가 Client에게 전달
   -> Client가 DONE

5. ack가 유실
   -> Network에서 ack 제거

6. Client timeout
   -> req를 다시 전송
```

따라서 예를 들어 ACK가 Network에 있을 때
```
                    ACK 전달
                   /
<1, 1, ack> ------<
                   \
                    ACK 유실
```
처럼 산 상태에서 두 개의 다음 상태가 가능해짐 -> 이것이 이 시스템의 nondeterminism

