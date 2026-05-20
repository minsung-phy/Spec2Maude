# How to test step-pure, step-read, step, and steps in wasm-exec-bs.maude

Note: `$mk-frame(...)` was removed from the generated strict C1 output.
Manual tests that need a concrete frame should now use the generated source
frame constructor:

```maude
RECFrameA2(locals, moduleinst)
```

For example, the old shape:

```maude
$mk-frame(VALS, fib-moduleinst)
```

should be written as:

```maude
RECFrameA2(VALS, fib-moduleinst)
```

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
> state 안에서 `ref.null func; throw_ref`를 실행하면 null reference 때문에 trap이 나는지 확인하는 테스트
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

5. Focused context smoke tests

5.1 label/br + suffix
```
search [5] in WASM-FIB-BS :
  step((fib-store ;
    RECFrameA2(
      CTORCONSTA2(CTORI32A0, 0)
      CTORCONSTA2(CTORI32A0, 5)
      CTORCONSTA2(CTORI32A0, 8)
      CTORCONSTA2(CTORI32A0, 8),
      fib-moduleinst)) ;
    CTORLABELLBRACERBRACEA3(0, eps, CTORBRA1(0))
    CTORLOCALGETA1(1))
  =>* C:Config .
```

Expected: exactly one solution, ending with:

```maude
(fib-store ;
  RECFrameA2(
    CTORCONSTA2(CTORI32A0, 0)
    CTORCONSTA2(CTORI32A0, 5)
    CTORCONSTA2(CTORI32A0, 8)
    CTORCONSTA2(CTORI32A0, 8),
    fib-moduleinst)) ;
  CTORLOCALGETA1(1)
```

5.2 br_if + suffix
```
search [5] in WASM-FIB-BS :
  step(((fib-store ; empty-frame).State ;
    CTORCONSTA2(CTORI32A0, 1) CTORBRIFA1(0) CTORLOCALGETA1(1)))
  =>* C:Config .
```

5.3 nop + suffix
```
search [5] in WASM-FIB-BS :
  step(((fib-store ; empty-frame).State ;
    CTORNOPA0 CTORLOCALGETA1(0)))
  =>* C:Config .
```

6. ModelCheck test
6.1 Load in terminal
``` 
maude modelcheck.maude
```

6.2 ModelCheck test
> [](done -> result-is(n)): 끝난 상태라면 결과가 n이어야함
```
red in WASM-FIB-BS-PROPS :
    modelCheck(steps(fib-config(i32v(0))), [](done -> result-is(0))) . 

red in WASM-FIB-BS-PROPS :
    modelCheck(steps(fib-config(i32v(1))), [](done -> result-is(1))) .

red in WASM-FIB-BS-PROPS :
    modelCheck(steps(fib-config(i32v(5))), [](done -> result-is(5))) .

red in WASM-FIB-BS-PROPS :
    modelCheck(steps(fib-config(i32v(5))), [] ~ trap-seen) .
```
