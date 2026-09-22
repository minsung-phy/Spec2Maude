# fib(5)의 잘못된 결과 6 탐색: Maude rewrite 비용 분석

2026-09-22, 기준 커밋 `3c35fafddcbdb811f2cd69c20bee33577bb4a726`.

## 결론

`fib(5)`가 `CONST(I64, 6)`으로 종료하는 상태를 탐색하면 **17,100 rewrites**가
발생한다. **174개 상태, 173개 간선의 단일 경로**를 끝까지 탐색하고
`No solution`으로 종료한다. 이 입력에서는 상태 폭발이 원인이 아니다.

확인된 주요 비용은 다음과 같다.

1. 매 Step마다 중첩된 LABEL/FRAME과 명령어 문맥을 내려갔다 복원한다.
   해당 heat/cool 자체가 **3,733회**, 명령어 문맥의 두 inequality 검사가
   **2,516회**, focus 선택 rule이 **503회**다. 합계 **6,752회, 39.49%**다.
   필요한 문맥 복원과 실패할 문맥 후보 검사 비용이 함께 포함돼 있다.
2. `CALL_REF`의 인자 경계를 정할 때 목록 분해 후보마다 함수 조회와 타입
   `Expand`를 다시 계산한다. **65개 후보 중 29개만 경계 조건을 만족**한다.
   나머지 **36개 후보에서도 조회·타입 전개를 끝낸 뒤 실패**한다.
3. 실제 BINOP는 **21회**지만, 정상 결과 rule과 trap rule이 같은 산술 함수를
   각각 계산한다. 탐색에서 **ADD 14회, SUB 28회**, 합계 **42회** 호출된다.
   두 번째 산술 계산분만 **1,176 rewrites**다. trap 가능성을 검사하는 의미는
   필요하지만, 그 검사를 위해 이미 계산한 값을 다시 구하는 비용은 공유 검토 대상이다.
4. 산술 dispatch와 입력 타입 검사도 작지 않다. `spectec-binop-(I64, ADD, 1, 1)`은
   **52 rewrites**, 그 안의 `iadd-(64, 1, 1)`은 **4 rewrites**다.
   `Inn = addrtype` alias를 경유해 동일한 타입 검사를 반복하는 사례도 확인됐다.

위 항목들은 일부 겹친다. 예를 들어 산술 재계산에는 타입 검사가 포함된다.
**항목별 수치를 더해 전체 절감 가능량으로 해석하면 안 된다.**
이번 작업은 원인 분석이며 translator, source hint, backend를 변경하지 않았다.

## 측정 대상과 재현

입력은 [fib.wat](evidence/fib5-profile-20260922/fib.wat)이다.
이 프로그램은 `n <= 1`이면 1을 반환하므로 정상 결과는 8이다.

```text
fib(n) = 1                         if n <= 1
         fib(n - 2) + fib(n - 1)   otherwise
```

| 항목 | 조건 |
|---|---|
| SpecTec revision | `acc6e834ff403c82554d081237f327346190ad96` |
| Maude | 3.5.1, build `Jul 16 2025 12:00:00`, macOS arm64 |
| frontend 환경 | Dune 3.23.1, `ocamlc` 5.1.0 |
| 입력 | export `fib`, 인자 `i64:5`, expected `i64:8`, rejected `i64:6` |
| 측정 전 working tree | clean |
| semantics | 현재 `translator/backend/semantics.maude`와 versioned generated output |
| query | `boot =>* finished(CONST(I64, 6))` |
| 상한 | 해 1개, 탐색 깊이 1,000,000; 별도 프로세스 timeout 60초 |
| 시간 집계 | Maude가 query에 출력한 CPU/real 시간. 로딩·컴파일·프로파일 출력 시간 제외 |

현재 translator로 별도 디렉터리에 새로 생성한 `output.maude`, `types.maude`가
versioned 파일과 byte-for-byte 일치함을 `cmp`로 확인했다.
파일 SHA-256과 측정값은 [measurements.json](evidence/fib5-profile-20260922/measurements.json)에 있다.

저장한 명령은 저장소 루트에서 다음과 같이 재실행할 수 있다.
`profile.maude`의 load 경로는 해당 파일을 기준으로 상대 경로다.

```sh
maude -no-banner -no-wrap docs/evidence/fib5-profile-20260922/profile.maude
maude -no-banner -no-wrap docs/evidence/fib5-profile-20260922/run-profile.maude
```

[profile.maude](evidence/fib5-profile-20260922/profile.maude)는 입력 모듈을 로드한 뒤
사용자가 요청한 순서대로 다음을 실행한다. 다른 `rew`나 `modelCheck`를 섞지 않았다.

```maude
set trace off .
set break off .
set clear profile on .
set profile on .
set show breakdown on .
search [1, 1000000] in WASM2MAUDE-MODELCHECK :
  boot =>* finished(CONST(I64, 6)) .
show profile .
```

입력 wrapper를 다시 생성하는 명령은 다음과 같다. 생성 파일에는 여러 query가
들어가므로 그대로 실행하면 마지막 query의 profile만 남을 수 있다.
이번 측정은 그 모듈 선언 뒤에 위의 단일 search를 붙였다.

```sh
dune exec bin/wasm2maude.exe -- modelcheck \
  docs/evidence/fib5-profile-20260922/fib.wat \
  --invoke fib --arg i64:5 --expect i64:8 --reject i64:6 \
  --steps 1000000 -o /tmp/fib5-profile-modelcheck.maude
```

증거 파일:

- [profile.log](evidence/fib5-profile-20260922/profile.log): 잘못된 결과 탐색의 전체 statement profile.
- [run-profile.log](evidence/fib5-profile-20260922/run-profile.log): 정상 `rew` 비교 profile.
- [supplementary.zip](evidence/fib5-profile-20260922/supplementary.zip): 5회 timing 로그,
  `show search graph` 결과, 국소 probe 명령과 로그, fresh translation 로그.
  압축 파일 안의 명령은 측정 당시 절대 경로를 보존한 snapshot이다.
  다른 checkout에서 전체 탐색을 재현할 때는 위의 상대 경로 명령을 사용한다.

## 매뉴얼에 따른 profile 해석

읽은 문서는 [Maude 3.5.1 manual](../reference/manual/Maude3.5.1-manual.pdf)이다.
아래 쪽수는 인쇄 쪽수이며 PDF 페이지 번호는 12를 더한다.

| 절 | 이 분석에 적용한 내용 |
|---|---|
| §21.1.5, pp.531–533 | statement별 rewrite, conditional statement의 LHS matches와 조건 fragment 통계. builtin은 symbol별 집계 |
| §21.1.6, p.541 | profiling/tracing/breakpoint는 실행 경로에 overhead를 추가하므로 시간 측정은 끄고 수행 |
| Appendix A.13, p.571 | `set profile on`, `show profile`, `set clear profile`의 의미와 기본값 |
| §4.3, pp.45–47; §5.2, pp.87–88 | 조건은 왼쪽부터 평가하며 associative matching에서 여러 치환을 시도할 수 있음 |
| §5.4.3, pp.95–96 | `search [n,m]`의 해 개수·깊이 상한, BFS, `=>1`과 `=>*`의 차이 |
| §4.4.8, pp.62–64 | `memo`는 equation 정상형의 재사용. rule 실행 전체를 메모하는 기능이 아님 |

조건 표의 열은 `Initial tries`, `Resolve tries`, `Successes`, `Failures`다.
`Resolve tries`는 backtracking으로 다음 해를 찾으려는 재시도를 뜻한다.
보통 `Initial + Resolve = Successes + Failures`다.

**Failures를 모두 서로 다른 잘못된 입력 수로 세면 안 된다.**
예를 들어 CALL_REF의 결정적인 matching 조건은 `65, 65, 65, 65`다.
처음 65번 성공한 뒤 추가 해가 없음을 확인하는 재시도 65번이 실패한 것이다.
함수 조회를 130번 처음부터 계산했다는 뜻이 아니다.

`rewrites`에는 builtin/equation 계산과 조건 내부의 rule 적용도 포함된다.
반면 조건 실패와 매칭 자체의 모든 CPU 작업이 rewrite 한 번씩으로 기록되지는 않는다.
`show profile`은 **statement별 CPU 시간이나 inclusive call stack을 제공하지 않는다.**
따라서 아래는 rewrite 소비처와 반복 작업의 진단이며, CPU 병목의 정확한 시간 비율은 아니다.

## 전체 결과와 비용 분해

| 명령 | 결과 | Equation | Rule | 합계 |
|---|---|---:|---:|---:|
| 잘못된 결과 6 search | No solution, 174 states | 14,010 | 3,090 | **17,100** |
| `rew [1000000] ... : boot` | `finished(CONST(I64, 8))` | 12,805 | 3,090 | **15,895** |

membership application과 narrowing은 모두 0이다.
저장한 statement profile의 rewrite를 합산하면 각각 위 총계와 정확히 일치한다.
profile을 끈 별도 Maude 프로세스 5회의 결과는 모두 174 states / 17,100 rewrites였다.

| 회차 | CPU ms | Real ms |
|---|---:|---:|
| 1 | 29 | 31 |
| 2 | 28 | 29 |
| 3 | 30 | 30 |
| 4 | 28 | 30 |
| 5 | 30 | 30 |

중앙값은 CPU **29ms**, real **30ms**다. 작은 입력의 ms 단위 측정이므로
작은 시간 차이를 유의미한 개선으로 주장하지 않는다.

다음 표는 중복 없이 합산한 분해다. 조건을 계산하는 하위 equation은 해당 rule의
직접 적용 횟수에 포함시키지 않았으며, 별도 guard 행 또는 마지막 행에 속한다.

| 직접 집계한 항목 | Rewrites | 전체 비율 |
|---|---:|---:|
| LABEL heat / cool | 933 + 903 = 1,836 | 10.74% |
| FRAME heat / cool | 519 + 504 = 1,023 | 5.98% |
| 명령어 문맥 heat / cool | 437 + 437 = 874 | 5.11% |
| 명령어 문맥의 두 inequality guard | 2,013 + 503 = 2,516 | 14.71% |
| `identifyFocus` 성공 rule | 503 | 2.94% |
| pure/read 식별 + bridge heat + cool | 169 × 3 = 507 | 2.96% |
| wrapper `execute-step` | 169 | 0.99% |
| 실제 `Step-pure`/`Step-read` leaf rule | 169 | 0.99% |
| 그 외 equation/builtin/초기화·종료 rule | 9,503 | 55.57% |
| **합계** | **17,100** | **100%** |

`len`/`lenAux` equation만 1,658회이며, record `value` 선택은 303회다.
이는 호출 위치가 합쳐진 수치다. 목록이 길어서 생긴 문제인지, 짧은 목록을
반복 조회해서 생긴 문제인지는 별도로 확인해야 한다.
이 fib에는 Wasm 선형 메모리 load/store가 없으므로 메모리 표현을 바꿀 근거는 없다.

그래프의 외부 `execute-step` 간선 169개는 내부의 `Step(C) => C2`를 조건으로 삼는다
([modelcheck-runtime.maude](../wasm2maude/modelcheck-runtime.maude), lines 65–66).
그 조건 안에서 발생한 heat/cool와 산술 계산이 외부 상태 169개로 따로 나타나지 않는다.
leaf 실행 내역은 BINOP 21, RELOP 15, LOCAL.GET 29, IF 15, BLOCK 15,
CALL 14, CALL_REF 15, LABEL 반환 30, FRAME 반환 15, 합계 169회다.
이것은 이 profile의 rule 집계이며 별도 SpecTec evaluator 계측 결과는 아니다.

## 1. 문맥 탐색: 큰 비용이지만 필요한 복원과 헛시도를 구분해야 한다

원문 `Step/ctxt-instrs`는 다음 조건으로 비어 있지 않은 바깥 문맥을 요구한다
([source](../spectec/wasm-3.0/4.3-execution.instructions.spectec), lines 35–39).

```spectec
rule Step/ctxt-instrs:
  z; val* instr* instr_1*  ~>  z'; val* instr'* instr_1*
  -- Step: z; instr* ~> z'; instr'*
  -- if val* =/= eps \/ instr_1* =/= eps
```

현재 생성 형태의 핵심은 다음과 같다. 생성 파일 lines 3009–3012,
생성기 `Context_rules.context_transitions`, `translator/reld.ml:1073–1153`에 있다.

```maude
crl [heating-ctxt-instrs] :
  Step(Z ; (STACK (OP REST))) => Step(Z ; FOCUS) ~> hole(PREFIX, POSTFIX)
  if STACK (OP REST) =/= OP
    /\ identifyFocus(Z, STACK, OP, REST)
       => { PREFIX | (Z ; FOCUS) | POSTFIX }
    /\ FOCUS =/= PREFIX (FOCUS POSTFIX) .
```

| 조건 | Initial | Resolve | Success | Failure |
|---|---:|---:|---:|---:|
| 첫 guard | 2,013 | 503 | 503 | 2,013 |
| focus 선택 | 503 | 503 | 503 | 503 |
| 마지막 guard | 503 | 437 | 437 | 503 |

첫 검사에서 처음부터 거절되는 후보는 **2,013 − 503 = 1,510개**다.
뒤의 503 실패는 성공 후 추가 해가 없음을 확인하는 재시도다.
focus까지 구한 후 마지막 검사에서 거절되는 후보는 **503 − 437 = 66개**다.
선택한 focus가 전체와 같은 경우까지 구하고 나서 버리는 작업이 실제로 있다.

두 guard에서 builtin inequality가 2,516회 발생한다. 전체 `_=/=_` 2,531회 중
나머지 15회는 IF의 조건 검사다. 첫 guard를 없애면 이른 거절도 없어지므로
rewrite 한 항목이 줄었다는 이유만으로 개선이라 판단할 수 없다.

한편 pure/read bridge는 각각 **2,060회** LHS에 매치하고, 식별 성공은 각각
**96회 / 73회**다. 이들의 낮은 성공률은 다양한 내부 Step 요청에 같은 bridge를
시도한다는 증거다. 식별 실패가 그대로 수천 번의 rewrite로 계수되지는 않으며,
얼마의 CPU를 쓰는지는 이 profile만으로 분리할 수 없다.

LABEL/FRAME은 재귀 호출로 깊어진 문맥을 매 Step 다시 방문한다. heat 횟수가
leaf 실행보다 큰 이유다. heat가 cool보다 많은 것도 실패한 내부 요청 경로가 있음을
보여준다. 하지만 **source의 문맥 복원 자체를 불필요하다고 결론내릴 수는 없다.**
검토할 대상은 source의 비어 있지 않은 문맥 조건과 모든 가능한 focus를 보존하면서
거절될 후보를 더 일찍 배제할 수 있는지다. 변경안이나 절감량은 이번에 검증하지 않았다.

## 2. CALL_REF: 경계가 틀렸는데도 같은 함수 타입을 먼저 계산한다

원문은 함수 타입에서 인자 수 `n`을 얻고, 그 수만큼의 값을 소비한다
([source](../spectec/wasm-3.0/4.3-execution.instructions.spectec), lines 183–189).

```spectec
z; val^n (REF.FUNC_ADDR a) (CALL_REF yy) ~> ...
-- if $funcinst(z)[a] = fi
-- Expand: fi.TYPE ~~ FUNC t_1^n -> t_2^m
```

현재 focus rule은 다음 순서다
([generated output](../translator/generated/output.maude), lines 2766–2770).

```maude
identifyFocus(Z, PREFIX (VAL- REF.FUNC-ADDR(A)), CALL-REF(YY2), POSTFIX)
  => { PREFIX | (Z ; (VAL- (REF.FUNC-ADDR(A) CALL-REF(YY2)))) | POSTFIX }
if N3 := instrSize(VAL-)
  /\ FI := spectec-funcinst(Z)[A]
  /\ FUNC T-1- -> T-2- := Expand(FI . 'TYPE)
  /\ N3 = len(T-1-) .
```

`PREFIX`와 `VAL-`가 모두 `ValList`라서 여러 분해가 가능하다.
LHS 65개 매치 모두 1–3번 조건에 처음 진입하고 성공하지만, 마지막 길이 조건을
만족하는 매치는 29개다. **36개 틀린 분해에서도 함수 조회와 Expand를 수행한다.**
함수 조회와 타입은 `Z, A`에 의존하며 `PREFIX/VAL-` 분할에는 의존하지 않는다.

전체 `Expand` 성공 81회는 focus 65회 + 실제 CALL_REF 실행 15회 + 최초 invoke 1회와
일치한다. 실제 함수 진입은 15회뿐이다. boundary용 계산 결과를 실제 실행 rule이
받아 쓰지 않고 다시 계산하는 중복도 있다.

실제 외부 state 3의 `Z`와 `CONST(I64, 5) REF.FUNC-ADDR(0)`을 가져와 focus helper만
완전히 탐색한 probe는 다음을 보여준다(`focus-call-ref.log`, supplementary archive).

- 첫 해까지 **64 rewrites**, 추가 해가 없음을 확인한 끝에는 **125 rewrites**.
- 유효한 `VAL- = CONST(I64, 5)`와 무효한 `VAL- = eps` 두 분해를 시도한다.
- 함수 조회부터 `Expand`까지의 식을 따로 reduce하면 **55 rewrites**다.

따라서 함수 타입 전개가 저렴한 이름 조회 한 번에 불과한 것은 아니다.
`Expand -> unrolldt -> unrollrt -> subst-*` 및 목록/record 계산까지 내려간다.

생성기 근거는 `translator/reld.ml`의
`Context_rules.focus_premises` (lines 762–851: boundary에 필요한 premise의 의존성 선택)와
`Context_rules.translate_pattern` (lines 1043–1071: focus pattern 생성)이다.
실제 IL의 `RuleD`, `RulePr`, `IfPr`, `LetPr`와 `ListN`으로 표현된 경계 정보가 대상이다.

검토할 개선은 **분할에 독립적인 계산의 반복을 피하는 것**이다.
구체적인 CALL_REF 이름을 translator에 하드코딩하는 변경이나, source premise 순서를
임의로 옮기는 변경은 이 분석에서 제안한 구현이 아니다.
가능한 focus 전체, binding, 부분적으로 정의된 식의 실패, source Step 경계를
보존하는 일반적인 hint/번역 형태가 확인돼야 한다.

## 3. BINOP: 성공 결과와 trap 조건이 같은 계산을 두 번 한다

원문은 정상 결과와 trap을 서로 다른 rule로 정의한다
([source](../spectec/wasm-3.0/4.3-execution.instructions.spectec), lines 956–962).

```spectec
rule Step_pure/binop-val:
  (CONST nt c_1) (CONST nt c_2) (BINOP nt binop) ~> (CONST nt c)
  -- if c <- $binop_(nt, binop, c_1, c_2)

rule Step_pure/binop-trap:
  (CONST nt c_1) (CONST nt c_2) (BINOP nt binop) ~> TRAP
  -- if $binop_(nt, binop, c_1, c_2) = eps
```

생성된 Maude도 두 조건에서 각각 `spectec-binop-`을 호출한다
([output](../translator/generated/output.maude), lines 7406–7410).
정상 rule은 LHS 21매치/21성공, trap rule은 LHS 21매치/**0성공**이다.
trap rule의 rewrite가 0이어도 조건 안의 계산 비용은 이미 발생했다.

| 국소 probe | 값 계산만 | 첫 정상 결과까지 | 모든 successor 확인 |
|---|---:|---:|---:|
| I64 ADD(1,1) | 52 | 53 | 106 |
| I64 SUB(5,2) | 58 | 59 | 118 |

probe의 `search [100,1] ... =>1 V:InstrList`는 가능한 해를 모두 확인했다.
예를 들어 ADD의 최종 106은 `52 × 2 + 정상 rule 1 + trap의 == 1`이다.

전체 search와 정상 rew의 차이는 정확히 **1,205 rewrites**다.
statement별 profile 차이는 다음처럼 설명된다.

```text
추가 ADD 계산  7 × 52 =   364
추가 SUB 계산 14 × 58 =   812
trap의 == 검사         =    21
IF의 추가 == 검사      =     8
합계                   = 1,205
```

즉 이번 입력에서는 search가 정상 rew보다 비싼 부분을 추가 상태 생성으로 설명할
필요가 없다. 뒤의 대안까지 검사하면서 생기는 계산으로 전부 설명된다.
단, `rew`는 가능한 동작 하나만 선택하므로 search를 대체할 수 없다.

계산 결과를 두 rule에서 공유할 여지는 있지만 **trap rule을 삭제할 근거는 없다.**
결과 목록의 모든 원소, 빈 목록, 실제 trap, partiality를 보존해야 한다.
각 rule 안에 지역 변수를 하나 추가하는 것만으로는 서로 다른 rule 사이의 재계산이
사라지지 않는다. 1,176은 관측된 두 번째 계산분이지, 구현 후 실측한 절감량이 아니다.

## 4. 타입 검사: 원시 덧셈보다 주변 계산이 크고 alias 중복이 보인다

`spectec-binop-(I64, ADD, 1, 1)`의 52 rewrites 중 원시 덧셈 경로
`iadd-(64,1,1)`은 4회다. 나머지 48회에는 dispatch, 폭 계산,
입력 타입·범위 검사와 그에 따른 Nat/Int 변환이 포함된다.
함수의 입력 정의역 검사까지 전부 쓸모없다고 해석해서는 안 된다.

다만 다음 중복은 생성식과 국소 profile에서 직접 확인된다.

```maude
-- ADD dispatch와 num-(INN)의 타입 검사에 각각 존재한다.
if typecheck(INN, addrtype)
  /\ typecheck(INN, Inn)
...
eq typecheck(VALUE3, Inn) = typecheck(VALUE3, addrtype) .
```

source의 `syntax Inn = addrtype`는
`spectec/wasm-3.0/1.2-syntax.types.spectec:55`에 있다.
두 번째 검사는 같은 `INN`의 `addrtype`을 다시 검사한다.
ADD 1회의 profile에서 `typecheck(I64, addrtype)`는 **6회**,
`typecheck(_, Inn)` alias equation은 **3회**, `size(I64)`도 **3회** 적용된다.
`typecheck(I64, Inn)`만 실행한 probe도 alias와 본체를 합해 정확히 2 rewrites다.

생성 경로는 `translator/decd.ml:322–354`의 `translate_equation_clause`,
`translator/param.ml:40–50`의 `translate_eq_conditions`,
`translator/typd.ml:70–82`의 `translate_alias`다.
이미 증명된 변수의 검사를 생략하는 `proven` 경로도 현재 존재한다.
alias와 이미 확인한 타입 사실을 중복 검사하지 않도록 할 여지는 있지만,
지원되지 않은 입력을 새로 허용하거나 원문의 clause 선택 범위를 넓혀서는 안 된다.

## 개선 검토 순서와 남은 한계

| 우선 검토할 사항 | 현재 확인한 사실 | 변경 전에 필요한 조건 |
|---|---|---|
| CALL_REF 사례에서 드러난 일반적인 boundary 계산 반복 | 틀린 후보 36개에서 조회·Expand 수행 | 분할 독립성, binding, 가능한 경계 전체와 source premise 의미 보존 |
| alias/타입 사실의 중복 검사 | 동일 addrtype을 반복 검사 | 현재 정의역·clause 선택·실패 결과 보존 |
| BINOP 결과 계산 공유 | 두 번째 계산 1,176 rewrites | 정상 결과의 모든 대안과 trap/부분성 보존, equation 정상형 재사용의 적용성 확인 |
| 문맥/bridge 후보 검사 | 초기에 1,510개 거절, focus 후 66개 거절 | 비어 있지 않은 context와 모든 successor 보존; matching 비용 포함한 재측정 |

이 표는 분석에서 얻은 검토 순서이며 새 최적화 계획이나 구현 완료 목록이 아니다.
현재 측정에서 소요 시간이 가장 큰 statement를 순위 매긴 것도 아니다.

매뉴얼의 `fibo` memo 예제는 equation으로 정의한 수학 함수다. 이 저장소의 fib는
Wasm CALL, LOCAL.GET, FRAME/LABEL을 실제로 실행하는 프로그램이므로,
fib 호출 결과만 메모해서 source 실행 경로를 생략하는 방식으로 가져올 수 없다.
순수한 equation helper에 대한 `memo`도 정상형·메모리 사용·cold/warm 조건을
검토해야 하며, 이번에는 적용하거나 성능 개선을 주장하지 않았다.

검증한 것은 현재 generated semantics의 재생성 일치, Maude 경고 없는 로드,
해당 입력의 탐색 완료, 5회 동일 rewrite 수, 국소 probe와 profile 합계다.
별도 LTL `modelCheck`, 다른 fib 입력의 scaling, official WAST 전체 suite,
임의 IL/프로그램에 대한 의미 보존 증명과 최적화 효과 측정은 수행하지 않았다.
현재 검색의 No solution은 이 프로그램·초기 상태에서 종료값 6이 없다는 결과이며,
일반적인 trap 부재나 모든 프로그램의 정확성을 뜻하지 않는다.
