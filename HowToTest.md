How to test about step-pure, step-read, step, steps in wasm-exec-bs.maude ?

1. Load in terminal
```
maude wasm-exec-bs.maude
```

2. step-pure test
```
rew [1] in WASM-FIB-BS : step-pure(CTORNOPA0) .
search [1] in WASM-FIB-BS : step-pure(CTORNOPA0) =>* eps .
```

3. step-read test
```
rew [1] in WASM-FIB-BS : step-read((((fib-store ; empty-frame).State) ; CTORREFNULLA1(CTORFUNCA0) CTORTHROWREFA0)) .
search [1] in WASM-FIB-BS : step-read((((fib-store ; empty-frame).State) ; CTORREFNULLA1(CTORFUNCA0) CTORTHROWREFA0)) =>* CTORTRAPA0 .
```

4. step & steps test
```
rew [1] in WASM-FIB-BS : step(fib-config(i32v(5))) .
rew [1] in WASM-FIB-BS : steps(fib-config(i32v(5))) . 
search [1] in WASM-FIB-BS : steps(fib-config(i32v(5))) =>* (fib-store ; empty-frame ; CTORCONSTA2(CTORI32A0, 5)) .
```

5. ModelCheck test
5.1 Load in terminal
``` 
maude modelcheck.maude
```

5.2 ModelCheck test
```
red in WASM-FIB-BS-PROPS :
    modelCheck(steps(fib-config(i32v(0))), [](done -> result-is(5))) . 
    --- 끝난 상태라면 결과가 0이어야 함

red in WASM-FIB-BS-PROPS :
    modelCheck(steps(fib-config(i32v(1))), [](done -> result-is(1))) .

red in WASM-FIB-BS-PROPS :
modelCheck(steps(fib-config(i32v(5))), [](done -> result-is(5))) .

red in WASM-FIB-BS-PROPS :
    modelCheck(steps(fib-config(i32v(5))), [] ~ trap-seen) .
```