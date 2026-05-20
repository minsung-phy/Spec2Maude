# Maude warning cleanup status

Updated: 2026-05-21

이 문서는 `load wasm-exec-bs.maude` 때 남는 warning/advisory를 현재 기준으로
분류한 것이다. warning을 0으로 만드는 것보다 중요한 기준은 C1 구조를 깨지
않는 것이다. 특히 source premise가 witness를 만들어야 하는 경우를 무작정
`==` 조건으로 바꾸면 실행이나 의미가 깨질 수 있다.

## 현재 count

`scripts/classify_maude_warnings.py` 기준:

- `assignment-fragment-advisory`: 0
- `used-before-bound`: 25
- `multiple-distinct-parses`: 95
- `duplicate-import-advisory`: 3

## 이번 pass에서 제거한 warning

### Category-pattern disjunction

Source 예:

```spectec
-- if t' = numtype \/ t' = vectype
```

예전 생성은 `NUMTYPE` / `VECTYPE` 같은 raw witness 변수를 만들 수 있어서
`used-before-bound`가 났다. 지금은 source category-pattern disjunction을 Bool
category predicate로 낮춘다.

```maude
($is-spectec-numtype(TQ) or $is-spectec-vectype(TQ))
```

제거된 warning:

- `instr-ok-select-impl`
- `instr-ok-array-new-data`
- `instr-ok-array-init-data`

### DecD TypA parameter lowering

Source 예:

```spectec
-- if $concat_(N, (j_1 j_2)*) = i*
```

예전에는 `TypA`/syntax argument lowering이 이미 바인딩된 대문자 parameter
mapping을 무시해서 raw `N`이 남았다. 지금은 term argument로 쓰이는 `TypA`는
바인더 mapping을 보존한다.

제거된 warning:

- `$ivadd-pairwise`의 `N used before bound`

## 남은 used-before-bound: validation

이들은 대부분 source premise가 중간 witness를 만들어야 하는 경우다.

- `deftype-sub-super`: source `typeuse*[i]`의 index/witness `i`
- `instr-ok-block`: `Instrs-ok(... t1* ->_(x*) t2*)`의 annotation witness `x*`
- `instr-ok-loop`: 위와 같은 `x*` witness
- `instr-ok-if`: 양쪽 branch의 `x_1*`, `x_2*` witness
- `instr-ok-try-table`: `Instrs-ok(... ->_(x*) ...)` witness
- `module-ok-r0`: iterated export premise가 만드는 export-name sequence `nms`

분류: `WITNESS_SYNTHESIS_LIMITATION`.

## 남은 used-before-bound: execution/def

- `step-read-br-on-cast-succeed`
- `step-read-br-on-cast-fail-succeed`
- `step-read-ref-test-true`
- `step-read-ref-cast-succeed`
- `allocmodule-r0`
- `evalexprs-r1`
- `evalglobals-r1`
- `instantiate-r0`
- `infer-instr-ok-arg2-r5`
- `infer-instr-ok-arg2-r6`
- `infer-instr-ok-arg2-r7`
- `infer-instr-ok-arg2-r24`

분류: 대부분 `WITNESS_SYNTHESIS_LIMITATION` 또는
`INIT_EVAL_HELPER_LIMITATION`.

## 남은 used-before-bound: numeric/vector helper

- `vcvtop` 계열 3개
- `vnarrowop`
- `ivextunop`
- `ivextbinop`
- `growmem`

분류: `NUMERIC_VECTOR_OUTPUT_WITNESS_LIMITATION` 또는
`PRELUDE_HELPER_LIMITATION`. source-valid focused probe로 하나씩 더 확인해야
한다.

## 남은 multiple distinct parses

95개가 남아 있다. 주 원인은 arithmetic expression, sequence concatenation,
generated `$map-*` equation의 precedence/associativity 모호성이다.

다음 cleanup 방향:

- generated arithmetic/sequence pretty-printer에 일관된 괄호 정책 적용
- Maude associative sequence operator와 arithmetic operator가 섞이는 곳 우선 확인
- warning 숫자를 줄이기 위해 source premise를 삭제하거나 바꾸지는 않는다

## 남은 duplicate-import-advisory

3개가 남아 있다. `dsl/pretype.maude`의 record update operator가 여러 import
path로 들어오는 구조와 관련된다.

다음 cleanup 방향:

- header/footer cleanup 또는 `dsl/pretype` cleanup 단계에서 import 구조 정리
