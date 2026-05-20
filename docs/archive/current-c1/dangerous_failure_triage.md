# 위험 실패 7개 focused triage

Updated: 2026-05-21

이번 triage는 full artifact audit에서 자동 sample 문제가 아니라 우선 확인해야
한다고 표시된 7개 항목만 다시 판 것이다.

대상:

- `STACK_OVERFLOW`: `$concatn`, `$ivbitmaskop`, `$vbitmaskop`
- `MAUDE_EXIT_2`: `clos-deftypes-r1`, `step-read-array-new-elem-alloc`,
  `alloctypes-r1`, `evalexprss-r1`

## 결과 요약

| 항목 | focused 결과 | 판정 |
|---|---|---|
| `$concatn` | stack overflow 제거, concrete chunk probe 통과 | generic translator bug 수정됨 |
| `$ivbitmaskop` | stack overflow 제거; source-shaped probe는 symbolic stuck | partial generic meta-lowering fixed, inverse/builtin limitation remains |
| `$vbitmaskop` | stack overflow 제거; `$ivbitmaskop` symbolic term으로 위임 | partial generic meta-lowering fixed, inverse/builtin limitation remains |
| `clos-deftypes-r1` | `rew $clos-deftypes(fib-type fib-type)`가 Maude result 생성 | full-audit sample/search 문제 |
| `step-read-array-new-elem-alloc` | source-shaped elem store + `n = 1` sample에서 solution 생성 | full-audit sample 문제 |
| `alloctypes-r1` | `rew $alloctypes(fib-source-type)`가 Maude result 생성 | full-audit sample/search 문제 |
| `evalexprss-r1` | non-empty `expr**` sample에서 stack overflow | nested sequence representation limitation |

## 적용한 generic 수정

### 1. `ListN` 길이 조건 보존

SpecTec source:

```text
def $concatn_(syntax X, (w^n) (w'^n)*, n) =
  w^n $concatn_(X, (w'^n)*, n)
```

기존 generated Maude는 `w^n`의 길이 조건이 없어 Maude가 `w^n = eps` 같은
비감소 split을 시도할 수 있었다. 이제 DecD lowering도 Step lowering과
동일하게 `ListN` binder에서 길이 조건을 생성한다.

대표 generated shape:

```maude
ceq $concatn(X, CONCATN1-WS WSQ, CONCATN1-N) =
  CONCATN1-WS $concatn(X, WSQ, CONCATN1-N)
  if len(CONCATN1-WS) == CONCATN1-N .
```

### 2. tail sequence 변수 sort 보정

`WSQ` 같은 source tail-sequence 변수는 recursive tail이므로 `eps`가 될 수
있어야 한다. 이전에는 일부 fallback sequence 변수가 `WasmTerminal`로 선언되어
마지막 `eps` tail을 못 잡았다. 선언 추론을 보정해서 이런 이름은
`WasmTerminals`로 선언되게 했다.

확인:

```maude
red $concatn(0, CTORI32A0, 1) .
=> CTORI32A0

red $concatn(0, CTORI32A0 CTORI64A0, 1) .
=> CTORI32A0 CTORI64A0

red $concatn(0, CTORI32A0 CTORI64A0, 2) .
=> CTORI32A0 CTORI64A0
```

## `$ivbitmaskop` / `$vbitmaskop`

Source:

```text
def $ivbitmaskop_(Jnn X M, v_1) = $irev_(32, c)
  -- if c_1* = $lanes_(Jnn X M, v_1)
  -- if $ibits_(32, c) =
        $ilt_($lsizenn(Jnn), S, c_1, 0)* ++ (0)^(32-M)

def $vbitmaskop_(Jnn X M, v) = $ivbitmaskop_(Jnn X M, v)
```

이전 generated rule은 핵심 meta-expression을 충분히 보존하지 못했다.

```maude
ceq $ivbitmaskop(CTORXA2(JNN, M), V1) = $irev(32, C)
  if CS1 := $lanes(CTORXA2(JNN, M), V1)
  /\ $ibits(32, C) := $ilt($lsizenn(JNN), S, CS1, 0) 0 .
```

문제:

- source의 `$ilt(...)*`가 단일 `$ilt(...)`처럼 낮아진다.
- source의 `(0)^(32-M)` 반복 길이 정보가 단순 `0`으로 낮아진다.
- `$ibits(32, c) = bits`는 `c`를 역방향으로 합성해야 한다. source에는
  `hint(inverse $inv_ibits_)`가 있지만 현재 translator는 inverse hint를
  operational하게 사용하지 않는다.

현재 translator는 이 중 source meta-expression 두 가지를 generic하게 낮춘다:

```maude
ceq $ivbitmaskop(CTORXA2(JNN, M), V1) = $irev(32, C)
  if CS1 := $lanes(CTORXA2(JNN, M), V1)
  /\ ($ibits(32, C)
      == $map-Silt-a4-s2($lsizenn(JNN), S, CS1, 0)
         $repeat(0, 32 - M)) .
```

적용된 generic lowering:

- non-variable `e*`를 sequence map으로 낮추기;
- `e^n` repeat meta-expression을 generic하게 낮추기;
- helper map의 recursive tail은 `slice(..., 1, len(...) - 1)`로 진행시켜
  associative matching의 non-progress split을 피하기.

Focused 결과:

```maude
red $map-Silt-a4-s2(32, S, 1 0 2 0, 0) .
=> 0 0 0 0

red $repeat(0, 4) .
=> 0 0 0 0

red $ivbitmaskop(CTORXA2(CTORI32A0, 4), 0) .
=> $ivbitmaskop(CTORXA2(CTORI32A0, 4), 0)
```

따라서 stack overflow는 제거되었다. 다만 완전한 값 계산은 아직 되지 않는다.
남은 이유는 source `hint(inverse $inv_ibits_)`를 condition solving에
operational하게 쓰지 못하고, `$lanes` / `$ibits` 계열 builtin 의미가 현재
Maude prelude에 충분히 실행 가능하게 구현되어 있지 않기 때문이다. 이 부분은
hardcoded vector-specific shortcut으로 넣지 않고 별도 limitation으로 남긴다.

## `MAUDE_EXIT_2` 네 항목 재판정

`clos-deftypes-r1`와 `alloctypes-r1`는 full audit이 RHS의 premise-produced
변수를 임의 값으로 채워 “정확히 그 RHS로 search”하면서 Maude internal error를
낸 것이었다. 함수형 `crl`은 `rew lhs`로 보는 것이 더 안전하다.

`step-read-array-new-elem-alloc`도 full audit sample이 source-shaped
elem store와 `n = 1` witness를 만들지 못한 문제였다. focused sample:

```maude
search [1] :
  step-read((Z-ELEM0 ;
    CONST I32 0 CONST I32 1 ARRAY.NEW_ELEM 0 0))
  =>+ R:StepReadConf .
```

은 solution을 낸다.

`evalexprss-r1`은 sample만의 문제가 아니다. Source type은 `expr**`, 즉
expression-list들의 list인데 현재 C1 Maude 표현은 이를 flat `WasmTerminals`로
낮춘다. 그래서 recursive split에서 `expr* = eps`, `expr'** = same term` 같은
비감소 split이 가능해져 stack overflow가 난다. 이건 nested sequence/grouping
representation을 다시 설계해야 하는 limitation이다.

추가로 `$evalexprss`가 호출하는 `$evalexprs`에도 output-witness 문제가 있다.
Source premise는 다음 모양이다.

```text
-- Eval_expr: z; expr ~>* z'; ref
```

현재 generated Maude는 이 premise를 다음처럼 보존한다.

```maude
Eval-expr(Z, EXPR, ZQ, REF) => valid
```

Exact output을 알고 주면 `Eval-expr` 자체는 동작한다.

```maude
rew Eval-expr((fib-store ; empty-frame),
              CONST I32 7,
              (fib-store ; empty-frame),
              CONST I32 7) .
=> valid
```

하지만 output을 변수로 두면 Maude rewriting은 `ZQ`와 `REF`를 합성하지 못한다.

```maude
search Eval-expr((fib-store ; empty-frame),
                 CONST I32 7,
                 ZQ:State, VALS:WasmTerminals) =>* valid .
=> No solution
```

임시 실험으로 다음 세 가지를 적용하면 concrete `$evalexprs` / `$evalexprss`
probe는 통과한다.

1. `Eval-expr(...) => valid` premise를 source rule의 본문인
   `steps((z ; expr)) => (z' ; ref)`로 펼친다.
2. premise output에 들어가는 `FREE-*` witness를 상수가 아니라 Maude 변수로 둔다.
3. flat `expr**` recursion에서 첫 조각을 non-empty처럼 다루어 비감소 split을 막는다.

그러나 이 조합은 strict C1-final로 넣지 않았다. 이유는 두 가지다.

- source의 `Eval_expr` premise를 그대로 쓰지 않고 relation body를 펼친다.
- `expr**`의 group boundary를 보존하지 못하고, flat sequence 위에서 실행을
  맞추는 타협이 된다.

따라서 C1-compatible한 해결 방향은 둘 중 하나다.

- `T**` / `(T*)*`를 source-derived nested-sequence/group representation으로
  낮춘다.
- 또는 C2 execution layer에서 output-bearing relation premise solver를 둔다.

## Audit script 변경

`scripts/audit_output_bs_total_concrete.py`는 이제:

- `$...` 함수형 `rl/crl`은 instantiated RHS search 대신 `rew lhs`로 검사한다.
- `step-read`, `step-pure`, `step`, `steps`는 concrete result sort로 search한다.
- `$ivbitmaskop`, `$vbitmaskop`, `$evalexprss`의 남은 구조적 실행 한계를
  known limitation으로 분류한다.

`scripts/audit_output_bs_rules_concrete.py`는 source-shaped elem store sample과
`array.new_elem`의 `n = 1` sample을 추가했다.
