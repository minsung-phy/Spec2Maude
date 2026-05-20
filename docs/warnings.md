# Maude warning cleanup status

Updated: 2026-05-21

이 문서는 `load wasm-exec-bs.maude` 때 남는 warning/advisory를 현재 기준으로
분류한 것이다. 목표는 warning 숫자만 줄이는 것이 아니라, C1 source structure를
깨지 않는 범위에서 안전하게 줄이는 것이다.

## 현재 count

`scripts/classify_maude_warnings.py` 기준 최신 결과:

- `assignment-fragment-advisory`: 0
- `multiple-distinct-parses`: 0
- `used-before-bound`: 25
- `duplicate-import-advisory`: 3

주의: 위 count는 `load wasm-exec-bs.maude ; q` 기준이다. 실제 `red/search`
명령을 함께 실행하면 Maude builtin/pretype associative operator에 대한
membership-axiom warning 11개가 추가로 출력될 수 있다. 현재 smoke 결과는
정상이며, 이 warning은 별도 `dsl/pretype` / builtin sort 설계 cleanup에서 본다.

현재 남은 warning은 크게 두 종류다.

1. source premise가 output witness를 만들어야 하는 `used-before-bound`.
2. `dsl/pretype` import 구조에서 오는 duplicate import advisory.

## 이번 pass에서 제거한 warning

### Assignment fragment advisory

Maude가

```maude
X := expr
```

에서 `X`가 이미 bound되어 있다고 알려주던 advisory family는 제거했다. 이미
bound된 값을 확인하는 경우에는 assignment가 아니라 equality condition으로
생성한다. 이 변경은 source premise를 삭제하지 않고, Maude condition의 binding
mode만 더 정확하게 출력하는 cleanup이다.

### Category-pattern disjunction

Source 예:

```spectec
-- if t' = numtype \/ t' = vectype
```

예전 생성은 `NUMTYPE` / `VECTYPE` 같은 raw witness 변수를 만들 수 있어서
`used-before-bound`가 났다. 지금은 source category-pattern disjunction을 Bool
category predicate로 낮춘다.

```maude
_or_($is-spectec-numtype(TQ),$is-spectec-vectype(TQ))
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

### Multiple distinct parses

`multiple distinct parses` 95개는 모두 제거했다.

원인은 source premise 문제가 아니라 generated Maude expression의
precedence/associativity 모호성이었다. 예를 들어 arithmetic / Bool / 비교
operator와 sequence concatenation이 섞일 때 Maude parser가 여러 parse를 만들 수
있었다.

수정 방향:

- arithmetic operator를 prefix form으로 출력한다.
  - `_+_(A,B)`, `_-_(A,B)`, `_*_(A,B)`, `_quo_(A,B)`, `_rem_(A,B)`,
    `_^_(A,B)`
- Bool / comparison operator도 prefix form으로 출력한다.
  - `_and_(A,B)`, `_or_(A,B)`, `_==_(A,B)`, `_=/=_(A,B)`, `_<_(A,B)`,
    `_<=_(A,B)`, `_>_(A,B)`, `_>=_(A,B)`
- generated `$map-*` helper의 `slice(..., len(...) - 1)` 같은 표현도 prefix
  arithmetic으로 출력한다.

이 변경은 같은 Maude operator를 더 명확한 concrete syntax로 출력하는 것이다.
source rule 구조나 premise 개수는 바꾸지 않는다.

## 남은 used-before-bound: validation

아래 6개는 validation relation에서 source premise가 중간 witness를 만들어야 하는
경우다.

| label | variable | classification |
|---|---|---|
| `deftype-sub-super` | `DEFTYPE-SUB-SUPER1-I` | `WITNESS_SYNTHESIS_LIMITATION` |
| `instr-ok-block` | `INSTR-OK-BLOCK5-XS` | `WITNESS_SYNTHESIS_LIMITATION` |
| `instr-ok-loop` | `INSTR-OK-LOOP6-XS` | `WITNESS_SYNTHESIS_LIMITATION` |
| `instr-ok-if` | `INSTR-OK-W-IF7-XS1` | `WITNESS_SYNTHESIS_LIMITATION` |
| `instr-ok-try-table` | `INSTR-OK-TRY-TABLE24-XS` | `WITNESS_SYNTHESIS_LIMITATION` |
| `module-ok-r0` | `MODULE-OK-R00-NMS` | `WITNESS_SYNTHESIS_LIMITATION` |

예:

- `Instr_ok/block`의 source premise
  `Instrs_ok: ... instr* : t_1* ->_(x*) t_2*`에서 `x*`는 conclusion에 없는
  output witness다.
- `Module_ok`의 export premise는 `nms` 같은 export-name sequence witness를
  만든다.

이들은 단순히 `:=`를 `==`로 바꾸면 해결되는 문제가 아니다. Maude rewriting이
source relation premise의 output witness를 합성해야 한다.

## 남은 used-before-bound: execution/def

아래 12개는 execution relation, init/eval helper, 또는 validation inference
overlay에서 output witness가 필요한 경우다.

| label | variable | classification |
|---|---|---|
| `step-read-br-on-cast-succeed` | `STEP-READ-BR-ON-CAST-SUCCEED2-RT` | `OUTPUT_WITNESS_SYNTHESIS_LIMITATION` |
| `step-read-br-on-cast-fail-succeed` | `STEP-READ-BR-ON-CAST-FAIL-SUCCEED4-RT` | `OUTPUT_WITNESS_SYNTHESIS_LIMITATION` |
| `step-read-ref-test-true` | `STEP-READ-REF-TEST-TRUE67-RTQ` | `OUTPUT_WITNESS_SYNTHESIS_LIMITATION` |
| `step-read-ref-cast-succeed` | `STEP-READ-REF-CAST-SUCCEED69-RTQ` | `OUTPUT_WITNESS_SYNTHESIS_LIMITATION` |
| `allocmodule-r0` | `ALLOCMODULE0-FAS` | `INIT_EVAL_HELPER_LIMITATION` |
| `evalexprs-r1` | `EVALEXPRS1-ZQ` | `OUTPUT_WITNESS_SYNTHESIS_LIMITATION` |
| `evalglobals-r1` | `EVALGLOBALS1-ZQ` | `OUTPUT_WITNESS_SYNTHESIS_LIMITATION` |
| `instantiate-r0` | `INSTANTIATE0-IFS` | `INIT_EVAL_HELPER_LIMITATION` |
| `infer-instr-ok-arg2-r5` | `INSTR-OK-BLOCK5-XS` | `WITNESS_SYNTHESIS_LIMITATION` |
| `infer-instr-ok-arg2-r6` | `INSTR-OK-LOOP6-XS` | `WITNESS_SYNTHESIS_LIMITATION` |
| `infer-instr-ok-arg2-r7` | `INSTR-OK-W-IF7-XS1` | `WITNESS_SYNTHESIS_LIMITATION` |
| `infer-instr-ok-arg2-r24` | `INSTR-OK-TRY-TABLE24-XS` | `WITNESS_SYNTHESIS_LIMITATION` |

이 family는 C1 source structure와 Maude executability 사이의 gap이다. 고치려면
generic mode-aware solver나 C2 execution layer 쪽 설계가 필요할 가능성이 높다.

## 남은 used-before-bound: numeric/vector helper

아래 7개는 source DecD equation이 계산 중간 sequence 또는 output 값을 premise에서
만드는 경우다.

| family | variable | classification |
|---|---|---|
| `vcvtop` | `VCVTOP0-CS`, `VCVTOP1-CS`, `VCVTOP2-CS` | `NUMERIC_VECTOR_OUTPUT_WITNESS_LIMITATION` |
| `vnarrowop` | `VNARROWOP0-CQS1` | `NUMERIC_VECTOR_OUTPUT_WITNESS_LIMITATION` |
| `ivextunop` | `IVEXTUNOP0-CQS1` | `NUMERIC_VECTOR_OUTPUT_WITNESS_LIMITATION` |
| `ivextbinop` | `IVEXTBINOP0-CQS1` | `NUMERIC_VECTOR_OUTPUT_WITNESS_LIMITATION` |
| `growmem` | `GROWMEM0-IQ` | `OUTPUT_WITNESS_SYNTHESIS_LIMITATION` |

이들은 source-valid focused probe로 계속 좁혀야 한다. 현재 단계에서는
vector-specific shortcut을 추가하지 않는다.

## 남은 duplicate-import-advisory

3개가 남아 있다. `dsl/pretype.maude`의 record update operator가 여러 import
path로 들어오는 구조와 관련된다.

다음 cleanup 방향:

- header/footer cleanup 또는 `dsl/pretype` cleanup 단계에서 import 구조 정리.
- C1 relation/rule semantics를 건드리지 않고 처리할 수 있는지 확인.
