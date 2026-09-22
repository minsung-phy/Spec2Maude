# SpecTec IL → Maude 변환 워크스루

이 문서는 `translator/`를 처음 읽는 연구자를 위한 안내서다. 목표는 **입력 IL의 어떤 패턴을 보고, 어떤 재귀 호출을 하며, 어떤 Maude 선언·식·규칙을 만드는지** 설명하는 것이다. `wasm2maude/`의 프로그램 인코딩이나 모델체킹 driver는 주제가 아니다.

먼저 한 문장으로 읽으면 다음과 같다.

> 전체 IL에서 이름·타입·hint 정보를 모은 뒤, `TypD`, `DecD`, `RelD`를 나누어 방문하고 그 안의 식과 premise를 재귀 번역한다. 결과는 OCaml 자료형인 **Maude IL**이며, 마지막 출력기가 이를 Maude 문자열로 만든다.

읽는 순서는 요청한 여섯 단계다.

1. [Prescan 전체: hint를 포함한 사전 수집](#1-prescan-전체)
2. [일반 변환: syntax, def, rule, type/argument, expression/path, premise, iteration](#2-일반-변환-방법론-hint-선택-분기는-4절)
3. [방법론으로 제시할 재귀 OCaml/의사코드](#3-방법론으로-제시할-재귀-코드)
4. [Hint가 선택하는 특수 변환](#4-hint가-선택하는-특수-변환)
5. [현재 한계와 수동 relation backend의 자동화 의견](#5-현재-한계와-relation-backend-자동화)
6. [Maude IL의 구조와 출력](#6-maude-il)

## 읽기 전에: 이름과 예제 표기

| 용어 | 이 프로젝트에서 뜻하는 것 |
| --- | --- |
| SpecTec source | `spectec/wasm-3.0/*.spectec`에 작성한 언어 명세 |
| SpecTec IL | frontend가 elaboration한 `Il.Ast.script`; 실제 정의는 [ast.ml](../spectec/lib/il/ast.ml) |
| `TypD` / `InstD` | syntax 선언 전체 / 그 선언의 타입 인스턴스 |
| `DecD` / `DefD` | 함수 선언 전체 / 함수의 개별 clause. **`DefD`가 최상위 함수 선언은 아니다.** |
| `RelD` / `RuleD` | relation 선언 전체 / 개별 추론 규칙 |
| `exp` / term | 입력은 SpecTec IL의 `exp`; 출력은 Maude IL의 `term`. 입력에 별도 `TermD`는 없다. |
| Maude IL | 이 저장소에서 정의한 **출력용 OCaml AST**. SpecTec IL도, 외부 표준 중간언어도 아니다. |
| backend | 생성된 Maude가 사용하는 고정 연산·수동 구현. IL AST를 방문하는 OCaml translator와 역할이 다르다. |

아래 단어도 먼저 알아두면 코드를 읽기 쉽다.

- **premise:** 규칙이나 함수 clause가 적용되려면 만족해야 하는 조건. `-- if i <= j`가 한 예다.
- **pattern / binding:** 이미 있는 값의 구조를 맞추어 변수 값을 얻는 일. `REF(NULLS, HT) := value`에서 `NULLS`, `HT`를 얻는다.
- **bound:** 앞의 입력·조건에서 변수 값을 이미 얻은 상태.
- **capture:** 반복이나 후속 계산에서 다시 사용할 바깥 변수. helper·hole의 인자로 저장한다.
- **mixop:** 값이 들어갈 구멍과 고정 atom을 함께 가진 표기. 예를 들어 `REF % %`, `% ~> %`이며, `%`는 이 문서에서 구멍을 나타낸다.

예제의 규칙:

- **SpecTec** 블록은 명시한 실제 파일의 발췌다. 설명과 무관한 문서용 hint와 줄바꿈은 생략·정리할 수 있다. `설명용 조각`이라고 표시한 경우에만 문법 패턴을 짧게 조합했다.
- **IL AST** 블록은 실제 constructor에 맞춘 **읽기용 골격**이다. `phrase`의 `.at`, expression의 `.note`, 일부 quantifier·coercion은 생략한다. 실제 `mixop`은 문자열이 아니라 atom 목록들의 구조다. 아래의 `mixop("...")`는 읽기용 표기다.
- `Q`, `ps`, `e`, `t`, `G`는 각각 quantifier 목록, premise 목록, expression, type, generator 목록의 메타변수다. `CaseE("I32", ...)`의 문자열도 실제로는 mixop이다.
- **Maude 원문 발췌**는 현재 [output.maude](../translator/generated/output.maude)와 일치한다. **변환 도식**은 변수명·괄호·부가 guard를 단순화한 설명이며 그대로 실행하는 완전한 모듈이 아니다.
- `eq`는 식 계산, `ceq`는 조건부 식 계산, `rl`은 rewrite 전이, `crl`은 조건부 rewrite 전이다. `P := E`는 **계산한 E를 패턴 P에 매칭해 변수를 얻는 조건**이고, `E => P`는 **rewrite 결과를 P에 매칭하는 조건**이다.

실제 OCaml에서 `exp.it`는 constructor, `exp.at`는 source 위치,
`exp.note`는 elaboration이 붙인 타입이다. 위치를 생략한 설명용 AST와 달리
실제 translator는 타입 정보를 sort·boxing·coercion 판단에 사용한다.

작성 기준은 2026-09-22의 코드 `3c35fafddcbdb811f2cd69c20bee33577bb4a726`이다. 입력 SpecTec은 [REVISION](../spectec/REVISION)의 `acc6e834ff403c82554d081237f327346190ad96`이며 로컬 번역 hint가 추가되어 있다. 이 revision의 [Language.md][language], [formal IL README][formal-readme], [formal reduction][formal-reduction]을 함께 확인했다. 이들의 적용 경계는 5절에서 설명한다.

# 1. Prescan 전체

## 1.1 왜 먼저 전체를 읽는가

`CallE("f", args)`를 만났을 때 `f`가 일반 함수인지, 함수 인자인지, builtin인지 알아야 한다. `IterE` 안의 자유변수는 뒤에서 생성할 helper의 인자가 되어야 한다. constructor를 어떤 Maude sort로 선언할지도 해당 source 타입·hint를 알아야 정할 수 있다.

따라서 prescan의 결과는 **Maude 프로그램이 아니라 번역 환경 `index : Prescan.t`**다. IL 식의 실행 결과를 미리 계산하는 단계가 아니다.

전체 경로는 [bin/spec2maude.ml](../bin/spec2maude.ml)의 `load_script`, `emit_script`와 [def.ml](../translator/def.ml)의 `translate_script`에서 시작한다.

```text
21개 .spectec
  → Parse.parse_file
  → Elab.elab
  → Il.Ast.script
  → Prescan.scan
       ├─ Hintd.scan_sorts → Hintd.scan_source
       ├─ 선언·hint·이름·변수·함수 인자·iteration 수집
       ├─ relation policy / inverse / choice / body 지원 여부
       └─ Hintd.scan_heatcool → Hintd.scan_contexts
  → 각 정의와 필요한 helper를 Maude IL로 번역
  → 변수·선언·조건 정리
  → Maude_emit → types.maude + output.maude
```

`Hintd.scan_sorts`는 `Prescan.scan` **안에서** 호출한다. 별도로 실행하는 두 translator가 아니다. 이 초기 단계에서 생기는 `Il.Env`는 타입 선언·인스턴스를 찾고 표현을 판단하는 데 사용한다. 일부 `Il.Eval.reduce_typ`/`reduce_typdef` 호출은 타입 alias·인스턴스 정리를 위한 구현 수단이다. 이를 Wasm evaluator를 복제하는 방법론으로 설명해서는 안 된다.

## 1.2 첫 번째 수집: `Hintd.scan_source`와 `scan_sorts`

구현: [hintd.ml](../translator/hintd.ml)의 `scan_source`, `scan_sorts`.

| 읽는 패턴 | 수집·검사하는 정보 | 이후 사용하는 곳 |
| --- | --- | --- |
| `TypD(id, params, insts)` | 타입별 `InstD` 목록 | alias 확장, constructor 소유 타입, sort 선택 |
| `RelD(...)` | relation의 parameter, mixop, 규칙 목록 | heat/cool의 relation·규칙 조회 |
| `HintD(TypH(id, hints))` | 타입 hint 목록 | `maude_sort`, `maude_subsort`, `maude_proper` |
| `HintD(RuleH(rel, rule, hints))` | 규칙 hint와 원문 위치 | `k_heatcool` 대상 검증 |
| `IterT(VarT(id,...), List/List1/ListN)` | 목록으로 쓰이는 source 타입 | typed list가 필요한 타입 판별 |

`scan_sorts`는 위 정보를 다음 순서로 정리한다.

1. `maude_sort`가 붙은 타입과 hint 위치를 찾는다.
2. `maude_subsort`의 edge를 만들고, 대상·cycle을 검사한다.
3. sort를 subsort 관계에 따라 정렬한다.
4. `maude_proper`가 지정한 제외 타입과 proper sort를 계산한다.
5. 목록으로 쓰이는 annotated 타입을 찾고, 지원하는 하나의 subsort chain인지 검사한다.
6. `VariantT`와 투명한 포함 관계를 따라 constructor의 소유 타입을 찾는다.
7. `annotated`, `edges`, `proper`, `owners`, `lists`, 타입 환경을 반환한다.

**실제 예:** source의 `val`에 `hint(maude_sort) hint(maude_subsort "instr")`, `instr`에 `hint(maude_sort) hint(maude_proper "val InstrProper")`가 있다. 이 정보로 `val < instr`, `InstrProper < instr`, typed list를 정한다. `CONST`, `DROP`이라는 Wasm 이름을 보고 이 분류를 선택하는 것이 아니다. 정확한 출력은 4.1절에 있다.

## 1.3 두 번째 수집: `Prescan.scan`의 모든 주요 정보

구현: [prescan.ml](../translator/prescan.ml)의 `type t`, `scan`.

| 수집 항목 | 실제 입력 근거와 처리 | 출력 정보 / 소비자 |
| --- | --- | --- |
| 타입·함수·relation 선언 | `TypD`, `DecD`, `RelD`, 중첩 `RecD`를 순회 | `type_env`, `type_definitions`, 함수 signature, relation mixop |
| 모든 top-level hint | `HintD`; `RecD` 안까지 `collect_hints`로 방문 | `hints`; 함수·relation policy 분류 |
| 이름 | source id와 mixop, 예약된 backend 이름 | `names`; `typ_name`, `def_name`, `rel_name`, `mixop_name` |
| source 변수 | expression의 `VarE`, parameter·quantifier, `LetPr`, iteration binder | `(source id, sort)`별 Maude 변수; anonymous `_`는 발생 위치별 구분 |
| type parameter | `TypP`, scope 안의 대응 `VarT` | `type_parameters`; 타입을 상수 대신 Maude 변수로 번역 |
| 함수 parameter | `DefP(id, params, result)`와 로컬 scope | `definition_parameters`, signature별 함수 값 sort |
| 함수 값 인자 | `DefA`와 선언의 formal parameter 대응 | `definition_arguments`, `definition_values`, `definition_applications`; `apply` 생성 |
| 함수 parameter 호출 | `CallE`의 target이 현재 scope의 `DefP`인지 확인 | `definition_calls`; 일반 호출과 `apply` 구별 |
| expression iteration | `IterE(body, iterexp)` | `iterations`: body, generator, capture, owner, helper 이름 |
| premise iteration | `IterPr(body, iterexp)` | `premise_iterations`: check helper·출력 helper 후보 |
| inverse 계약 | `hint(inverse $g)`와 두 함수 signature | `ValidInverse {inverse_target; missing}` 또는 오류 이유 |
| membership choice | `DefD`의 마지막 premise가 미지 변수 `x <- xs`, RHS가 바로 `x` | `membership_choices`; 비결정적 선택 request/helper |
| rewrite 함수 | `maude_rule` 또는 위 choice shape | `rewrite_sorts`; 일반 값 함수와 request 함수 구별 |
| relation 정책 | mixop의 marker 위치와 relation hint | `Execution`, `Equation`, `Predicate`, `BackendCheck`, `BackendCompute` |
| otherwise 후보 이름 | execution relation의 규칙 ordinal | `relation_enabled_helpers`; 필요할 때만 helper 본문 생성 |
| heat/cool | `k_heatcool` 규칙, relation 입출력 수 | `heatcool`, `contexts`; 1.6절 |
| 본문 지원 여부 | builtin 여부, 미지원 relation을 premise에서 직접 참조하는 함수 | `definition_bodies`, `unsupported_relations`; 5.5절의 누락 경계 |

이름 정리의 실제 예는 `$min` → `spectec-min`이다. backend 예약 이름 `min`과 충돌하기 때문에 접두어가 생긴다. 밑줄·기호도 Maude에서 쓸 이름으로 정리한다. 따라서 논문에서 “source 이름을 그대로 복사한다”보다는 **source에서 결정한 이름을 충돌 없이 인코딩한다**고 쓰는 편이 정확하다.

## 1.4 Iteration prescan: generator와 capture

다음 실제 함수의 RHS를 보자. source: [1.2-syntax.types.spectec](../spectec/wasm-3.0/1.2-syntax.types.spectec), `$subst_comptype`.

```spectec
def $subst_comptype((STRUCT ft*), tv*, tu*) = STRUCT $subst_fieldtype(ft, tv*, tu*)*
```

읽기용 IL 핵심:

```ocaml
IterE (
  CallE ("subst_fieldtype", [ExpA ft; ExpA tvs; ExpA tus]),
  (List, [("ft", fts)]))
```

- `ft`는 매번 바뀌는 generator 원소다.
- `fts`는 generator의 원본 목록이다.
- `tvs`, `tus`는 반복 전체에서 같은 capture다. source에서 `tv*`, `tu*`라고 썼어도 여기에서는 각각 **목록 하나**를 capture한다.
- 함수 값·타입 값도 자유변수이면 `DefinitionCapture`·`TypeCapture`로 보관한다.

이 정보는 나중에 다음 인자 순서의 helper를 만드는 데 쓰인다.

```maude
map-subst-fieldtype(TV-3, TU-3, FT-)
```

prescan은 helper 후보 이름을 마련한다. 실제 번역 중 `forward_requested`, `projector_requested`, premise의 `check_requested`, 출력 요청이 기록되고 **필요한 방향의 helper**가 후속 단계에서 생성된다. 모든 `IterE`마다 무조건 재귀 helper가 생기지는 않는다.

## 1.5 Relation policy와 inverse의 prescan

relation의 이름으로 policy를 선택하지 않는다. [Mixop](../translator/mixop.ml)에서 marker의 위치를 찾아 입력·출력 component 수를 정한다.

| source 모양과 hint | policy | 의미 |
| --- | --- | --- |
| plain `~>` 또는 `~>*`, 별도 relation backend hint 없음 | `Execution {input_count; request_sort}` | 입력 request에서 출력으로 rewrite |
| plain `~~` + `maude_eq` | `Equation {input_count}` | 입력에서 출력을 계산하는 equation |
| `maude_predicate` | `Predicate` | 모든 component를 인자로 받아 성공 시 `true` |
| `maude_backend "check"` | `BackendCheck` | ground 검사를 수동 backend에 연결 |
| plain `:` + `maude_backend "compute"` | `BackendCompute {input_count}` | 출력 계산을 수동 backend에 연결 |
| 나머지·충돌하는 조합 | 오류 policy | 일반적인 relation 자동 번역으로 추측하지 않음 |

`inverse`는 다음 **signature 계약**을 검사한다.

```text
forward : known-args와 missing-arg → result
inverse : known-args, result       → missing-arg
```

빠진 인자가 하나로 결정되어야 하며, inverse의 마지막 인자는 forward의 결과 타입이어야 한다. 알려진 인자들의 순서와 signature도 맞아야 한다. 이 검사는 역함수의 수학적 정확성이나 모든 해의 보존을 증명하지 않는다.

## 1.6 Heat/cool prescan: 두 단계

구현: [hintd.ml](../translator/hintd.ml)의 `scan_heatcool`, `extract_context`, `scan_contexts`.

`scan_heatcool`은 다음을 확인한다.

- 인자 없는 `hint(k_heatcool)`가 규칙에 한 번 붙어 있다.
- 대상 relation이 execution policy다.
- 적어도 하나의 직접적인 execution `RulePr`가 있다.
- hinted rule 안의 `ElsePr`, `IterPr`, `NegPr`는 현재 거부한다.

그다음 `scan_contexts`는 이 중 **목록의 prefix / focus / suffix** 형태를 따로 추출한다. 입력의 목록을 세 부분으로 나누고, 내부 실행 premise가 focus를 실행하며, 반환 후 바깥 문맥을 복원하는 형태다. source의 type hint, quantifier 타입, AST 위치를 이용해 frame·proper sort·후보 패턴을 찾는다.

나머지 hinted rule은 일반 heat/cool 경로에서 premise별 continuation을 만든다. 현재 목록 context 하나만 구현된 상태가 아니다. **`Step/pure`, `Step/read`, `Steps/trans`, 세 중첩 context, `Eval_expr`도 현재 생성된다.**

## 1.7 Prescan과 혼동하기 쉬운 후속 처리

다음은 `Prescan.scan`의 반환 전에 끝나는 전역 수집과 구별해야 한다.

| 후속 처리 | 역할 |
| --- | --- |
| `Decd.prepare_clauses` | 함수 하나의 head들을 비교해 overlap·이미 확보된 타입 정보를 판단 |
| `Reld.lower_execution_rules` | relation 규칙의 source 순서를 따라 `otherwise` 선행 후보를 구성 |
| `Context_rules`의 capture 분석 | 실행 premise 뒤에 필요한 변수만 hole에 저장 |
| `Iter.translate_all`, `translate_premise_all` | 번역 중 요청된 helper 본문 생성 |
| `Def.normalize_module` | 생성 변수 이름 정리, 선언·조건 중복 정리, 호환 constructor 선언 통합 |

이 단계들은 계산한 값으로 원문을 대체하는 일반 최적화기가 아니다. **번역에 필요한 정보의 수집 → 각 AST case의 lowering → 출력 정리**로 설명하면 된다.

# 2. 일반 변환 방법론: hint 선택 분기는 4절

## 2.1 Syntax: `TypD → InstD → AliasT / StructT / VariantT`

구현: [typd.ml](../translator/typd.ml).

syntax 이름은 기본적으로 Maude sort가 아니라 **`SpectecType` 값을 만드는 연산자**가 된다. runtime 값은 constructor·tuple·record 등으로 표현하고, 그 값이 source 타입에 속하는지 `typecheck(value, type)`로 기술한다. 별도 sort를 선택하는 hint는 4.1절에서 다룬다.

### S1. `AliasT`: 이미 있는 타입에 이름을 붙이기

**SpecTec:** [1.1-syntax.values.spectec](../spectec/wasm-3.0/1.1-syntax.values.spectec).

```spectec
syntax u32 = uN(`32)
```

**IL AST:**

```ocaml
TypD ("u32", [], [
  InstD ([], [], AliasT (VarT ("uN", [ExpA (NumE (`Nat 32))])))
])
```

**Maude 원문 발췌:**

```maude
op u32 : -> SpectecType .
eq typecheck(VALUE, u32) = typecheck(VALUE, uN(32)) .
```

`u32`라는 runtime wrapper를 새로 씌우지 않는다. alias의 membership을 대상 타입의 membership에 연결한다. sequence boxing이 필요한 alias에는 boxed 값에 대한 검사식도 생성될 수 있다.

### S2. Parameter가 있는 `AliasT`

**SpecTec:** 같은 파일.

```spectec
syntax iN(N) = uN(N)
```

**IL AST:**

```ocaml
TypD ("iN", [ExpP ("N", VarT ("N", []))], [
  InstD (Q_N, [ExpA (VarE "N")], AliasT (VarT ("uN", [ExpA (VarE "N")])) )
])
```

**Maude 원문 발췌:**

```maude
op iN : Nat -> SpectecType .
ceq typecheck(VALUE, iN(N2)) = typecheck(VALUE, uN(N2))
  if typecheck(N2, N) .
```

parameter마다 Maude sort를 무한히 생성하지 않는다. `iN(32)`, `iN(64)`는 타입을 나타내는 **항**이다. `InstD`의 인자가 constructor나 계산 패턴이면 `translate_target`이 structural pattern 또는 매칭 조건으로 바꾼다.

### S3. `VariantT`: 이름 있는 case, payload 없음

**SpecTec:** [1.2-syntax.types.spectec](../spectec/wasm-3.0/1.2-syntax.types.spectec).

```spectec
syntax numtype = I32 | I64 | F32 | F64
```

**IL AST:**

```ocaml
TypD ("numtype", [], [InstD ([], [], VariantT [
  (mixop("I32"), (TupT [], [], []), []);
  (mixop("I64"), (TupT [], [], []), []);
  (* F32, F64도 동일 *)
])])
```

**Maude 원문 발췌:**

```maude
op numtype : -> SpectecType .
op I32 : -> SpectecTerminal [ctor] .
eq typecheck(I32, numtype) = true .
eq typecheck(I64, numtype) = true .
```

`I32`는 SpecTec의 atom을 사용하는 syntax case이고, `CaseE`는 그 값을 구성하는 IL expression이다. `I32` 자체가 IL AST constructor인 것은 아니다.

### S4. `VariantT`: 이름 있는 case, payload 있음

**SpecTec:** 같은 파일.

```spectec
syntax reftype = REF null? heaptype
```

**IL AST:**

```ocaml
VariantT [
  (mixop("REF % %"),
   (TupT [("null?", IterT (VarT ("null", []), Opt));
          ("heaptype", VarT ("heaptype", []))], Q, []), [])
]
```

**Maude 변환 도식:**

```maude
op REF : SpectecTerminals SpectecTerminal -> SpectecTerminal [ctor] .
ceq typecheck(REF(NULLS, HT), reftype) = true
  if typecheck(NULLS, null) /\ len(NULLS) <= 1
     /\ typecheck(HT, heaptype) .
```

case의 payload component마다 argument sort와 타입 조건을 만든다. `Opt`는 길이 1 이하라는 조건도 갖는다. type case에 자체 premise가 있으면 typecheck equation의 조건에 들어간다.

**중요한 구분:** 이 조건을 `CaseE`로 값을 만들 때마다 자동 실행하지는 않는다. 값 생성은 constructor application이고, 여기서는 명시적인 타입 검사 연산을 정의한다. 현재 언어 계약과 formal의 차이는 5.6절에 있다.

### S5. `VariantT`: hole-only case와 투명한 표현

**SpecTec:** [1.1-syntax.values.spectec](../spectec/wasm-3.0/1.1-syntax.values.spectec).

```spectec
syntax list(syntax X) = X*  -- if |X*| < $(2^32)
```

**IL AST:** 실제 elaboration에서 `AliasT`가 아니라 premise를 가진 `VariantT`다.

```ocaml
VariantT [
  (mixop("%"),
   (TupT [("X*", IterT (VarT ("X", []), List))], Q,
    [IfPr (CmpE (`LtOp, `NatT, LenE xs, pow_2_32))]), [])
]
```

**Maude 원문 발췌:**

```maude
ceq typecheck(X-, list(X)) = true
  if len(X-) < (2 ^ 32)
    /\ typecheck(X-, X) .
```

hole 하나뿐인 case는 `list.wrap` 같은 runtime constructor를 추가하지 않는다. 내부 값이 곧 외부 값이다. `CaseE`에서도 같은 투명한 표현을 사용한다.

hole가 여러 개인 예는 `syntax fieldtype = mut? storagetype`이다. 실제 IL은 두 component의 `TupT`를 가진 hole-only `VariantT`이고, 값은 `tuple(seq(MUTS) STORAGE)`로 표현한다. `seq`는 option/list 한 덩어리를 tuple의 한 component로 보존한다.

### S6. 범위 표기와 union은 먼저 elaboration 결과를 확인한다

**SpecTec:**

```spectec
syntax uN(N) = 0 | ... | $nat$(2^N-1)
syntax consttype = numtype | vectype
```

**IL AST:** 현재 frontend를 실행해 확인한 모양은 다음과 같다.

```ocaml
(* uN: 숫자 payload와 범위 premise를 가진 투명 case *)
VariantT [(mixop("%"), (TupT [("i", NumT `NatT)], Q,
  [IfPr range_condition]), [])]

(* consttype: frontend가 포함된 case들을 펼친다 *)
VariantT [case_I32; case_I64; case_F32; case_F64; case_V128]
```

**Maude 변환 도식:**

```maude
ceq typecheck(I, uN(N)) = true if 0 <= I /\ I <= 2 ^ N - 1 /\ parameter_guards .
eq typecheck(I32, consttype) = true .
eq typecheck(V128, consttype) = true .
```

첫 식의 실제 출력에는 `CvtE`에 따른 Nat/Int 변환이 남아 있다. 이 도식은 범위의 의미만 단순화했다. translator에 “범위 syntax 전용 AST case”나 “Wasm numtype union 전용 분기”가 있는 것이 아니다.

### S7. `StructT`: record 필드와 membership

**SpecTec:** [1.3-syntax.instructions.spectec](../spectec/wasm-3.0/1.3-syntax.instructions.spectec).

```spectec
syntax memarg = {ALIGN u32, OFFSET u64}
```

**IL AST:**

```ocaml
TypD ("memarg", [], [InstD ([], [], StructT [
  (ALIGN, (VarT ("u32", []), [], []), []);
  (OFFSET, (VarT ("u64", []), [], []), [])
])])
```

**Maude 원문 발췌:**

```maude
ceq typecheck({ (item('ALIGN, VALUE) ; item('OFFSET, VALUE14)) }, memarg) = true
  if typecheck(VALUE, u32)
    /\ typecheck(VALUE14, u64) .
```

source 필드 이름은 Maude quoted identifier인 `'ALIGN`, `'OFFSET`으로 보존한다. 현재 검사는 선언된 순서의 전체 record 패턴을 매칭한다. field 순서를 임의 변경한 record의 일반 검사기가 아니다.

필드가 모두 목록·option·합성 가능한 record이면 `recordConcat(left,right,type)` equation도 생성한다. source 예는 [validation context](../spectec/wasm-3.0/2.0-validation.contexts.spectec)의 `context`다. 각 목록 필드는 연결하고 option 필드는 `optionConcat`을 사용한다. `memarg`의 scalar 필드처럼 합성 불가능한 경우에는 이 equation을 만들지 않는다.

## 2.2 Definition: `DecD → DefD`

구현: [decd.ml](../translator/decd.ml). 일반 함수는 operator 선언과 clause별 `eq`/`ceq`가 된다.

### D1. 무조건 clause와 재귀 clause

**SpecTec:** [0.2-aux.num.spectec](../spectec/wasm-3.0/0.2-aux.num.spectec).

```spectec
def $sum(nat*) : nat
def $sum(eps) = 0
def $sum(n n'*) = $(n + $sum(n'*))
```

**IL AST:**

```ocaml
DecD ("sum", [ExpP ("_", IterT (NumT `NatT, List))], NumT `NatT, [
  DefD ([], [ExpA (ListE [])], NumE (`Nat 0), []);
  DefD (Q,
    [ExpA (CatE (ListE [VarE "n"], tail_iteration))],
    BinE (`AddOp, `NatT, VarE "n", CallE ("sum", [ExpA tail_iteration])), [])
])
(* tail_iteration = IterE(VarE "n'", (List, [("n'", VarE "n'*")])) *)
```

**Maude 원문 발췌:**

```maude
op sum : SpectecTerminals -> Nat .
eq sum(eps) = 0 .
ceq sum(N3 N--) = N3 + sum(N--)
  if typecheck(N3, n)
    /\ typecheck(N--, nat) .
```

두 가지 재귀를 구별하자. translator의 OCaml 재귀는 AST의 RHS를 방문한다. 생성된 `sum(N--)` 재귀는 **source 함수 자신의 계산**을 보존한 것이다.

### D2. Guard와 `otherwise`

**SpecTec:** 같은 파일.

```spectec
def $min(nat, nat) : nat
def $min(i, j) = i  -- if $(i <= j)
def $min(i, j) = j  -- otherwise
```

**IL AST:**

```ocaml
DecD ("min", params, NumT `NatT, [
  DefD (Q, [ExpA i; ExpA j], i, [IfPr (CmpE (`LeOp, `NatT, i, j))]);
  DefD (Q, [ExpA i; ExpA j], j, [ElsePr])
])
```

**Maude 원문 발췌:**

```maude
ceq spectec-min(I, J) = I if I <= J .
eq spectec-min(I, J) = J [owise] .
```

`ElsePr`만 보고 premise translator가 `false` 조건을 내는 것은 아니다. `Prem`이 `otherwise=true`를 반환하고, enclosing `Decd`가 equation attribute `[owise]`로 바꾼다.

이 대응의 전제는 source의 clause coherence와 해당 입력 범위다. 일반 clause 모두에 source 순서 우선순위를 구현한 별도 dispatcher가 있는 것은 아니다. [Language의 함수 설명][language]도 겹치는 clause의 결과 일치를 요구하며 이를 자동 증명하지 않는다.

### D3. 계산이 들어간 head pattern

**SpecTec 설명용 패턴:**

```text
def $f(CONSTR $g(x), x) = rhs
```

**IL AST:** `DefD(Q, [ExpA(CaseE(...CallE("g",...))); ExpA x], rhs, ps)`.

**Maude 변환 도식:**

```maude
ceq f(CONSTR(FIELD), X) = RHS if FIELD = g(X) /\ ... .
```

constructor 구조는 head에 남기고, 입력에서 얻은 `FIELD`와 계산값을 조건으로 비교한다. 반대로 `g`의 인자가 아직 미지이면 일반 함수 호출을 역으로 매칭할 수 없다. 지원하는 구조 패턴 또는 명시적인 inverse 계약이 필요하다. 실패하면 임의의 값을 선택하지 않고 거부한다.

### D4. 마지막 membership에서 결과를 선택하는 clause

이 경로는 **hint로 선택하지 않고 IL shape로 인식하는 일반 특수 패턴**이므로 여기 포함한다.

**SpecTec 실제 예:** [3.2-numerics.vector.spectec](../spectec/wasm-3.0/3.2-numerics.vector.spectec), `$vcvtop__` clause의 끝.

```spectec
  -- if v <- $inv_lanes_(Lnn_2 X M, c*)*
```

그 clause의 RHS는 `v`다. 앞 premise들에서 후보 목록은 정해지지만 `v`는 아직 정해지지 않는다.

**IL AST 핵심:**

```ocaml
DefD (Q, args, VarE "v",
  prefix @ [IfPr (MemE (VarE "v", candidates))])
```

**Maude 변환 도식과 실제 선택 rule:**

```maude
ceq f(ARGS) = choice(CANDIDATES) if PREFIX_CONDITIONS .
rl spectec-vcvtop---choice-291-0(CHOICE-PREFIX (V CHOICE-REST)) => V .
```

Maude의 associative matching으로 가능한 위치의 값을 선택한다. `[frozen ...]` request와 별도 결과 sort 관계를 사용한다. 하나의 deterministic equation으로 첫 원소만 고르면 source의 가능한 결과를 잃는다.

지원 조건은 좁다. 마지막 premise의 미지 원소가 단순 `VarE`이며 RHS와 같아야 한다. 임의의 existential constraint solver는 아니다. `maude_rule`과 이 choice 경로를 같은 함수에서 동시에 선택하면 거부한다.

## 2.3 Relation과 Rule: `RelD → RuleD`

구현: [reld.ml](../translator/reld.ml). 이 절은 relation에 별도 backend hint가 없는 plain execution relation을 설명한다.

### R1. 조건 없는 실행 규칙

**SpecTec:** [4.3-execution.instructions.spectec](../spectec/wasm-3.0/4.3-execution.instructions.spectec).

```spectec
relation Step_pure: instr* ~> instr*
rule Step_pure/nop:
  NOP ~> eps
```

**IL AST:**

```ocaml
RelD ("Step_pure", [], mixop("% ~> %"),
  TupT [("_", instrs_type); ("_", instrs_type)], [
    RuleD ("nop", [], mixop("% ~> %"),
      TupE [ListE [CaseE (mixop("NOP"), TupE [])]; ListE []], [])
  ])
```

**Maude 원문 발췌:**

```maude
sort Step-pure-Request .
subsort InstrList < Step-pure-Request .
op Step-pure : InstrList -> Step-pure-Request [frozen (1)] .
rl Step-pure(NOP) => eps .
```

`InstrList`라는 좁은 sort는 현재 source의 type hint 때문에 선택되어 있다. **rule lowering 자체**는 request를 결과로 rewrite하는 일반 방식이다. 결과를 request sort의 subsort로 두므로 입력 request와 반환값을 같은 rewrite kind 안에서 다룰 수 있다.

`Step_pure`의 relation 이름과 rule label `nop`은 서로 다른 정보다. 일반 생성 rule은 현재 label을 생략할 수 있다. source label이 항상 출력 label과 일대일로 남는다고 설명하지 않는다.

### R2. 조건 있는 규칙

**SpecTec:**

```spectec
rule Step_pure/select-true:
  val_1 val_2 (CONST I32 c) (SELECT (t*)?) ~> val_1
  -- if c =/= 0
```

**IL AST 핵심:**

```ocaml
RuleD ("select-true", Q, mixop("% ~> %"),
  TupE [input_list; ListE [SubE (val1, val_type, instr_type)]],
  [IfPr (CmpE (`NeOp, `NatT, unbox_c, NumE (`Nat 0)))])
```

실제 IL의 `unbox_c`는 투명 case의 `UncaseE`와 `ProjE(...,0)`다. 번역 결과에서는 표현이 같으므로 `C3`로 남는다.

**Maude 원문 발췌:**

```maude
crl Step-pure(VAL-1 (VAL-2 (CONST(I32, C3) SELECT(T--)))) => VAL-1
  if typecheck(VAL-1, val)
    /\ typecheck(VAL-2, val)
    /\ len(T--) <= 1
    /\ C3 =/= 0 .
```

입력 패턴에서 변수를 얻고, premise와 필요한 pattern/type 조건을 만들고, RHS를 재귀 번역한다. `crl`의 모든 조건이 성립해야 전이가 가능하다.

### R3. 출력 component가 여러 개인 relation

**SpecTec 설명용 조각:** `relation R: a ~> b; c`.

**IL AST:** `RelD(..., TupT[a_type; b_type; c_type], ...)`와 `RuleD(..., TupE[a;b;c], ps)`.

**Maude 변환 도식:**

```maude
crl R(A) => tuple(B C) if CONDITIONS .
```

relation marker 앞의 component가 입력이고 뒤가 출력이다. 출력 하나면 그 항을 반환하고, 둘 이상이면 tuple로 묶는다. 실제 Wasm의 `config`가 `CaseE` 하나로 표현된 경우에는 그 내부 `state; instrs`를 relation-level 다중 출력과 혼동하지 않는다.

### R4. 실행 relation의 `otherwise`

**SpecTec 실제 패턴:** 같은 실행 파일의 out-of-bounds trap 등에는 앞 규칙 다음에 `-- otherwise`가 온다.

**IL AST:** `RuleD(..., ElsePr :: remaining_prems)`.

**Maude 변환 도식:**

```maude
ceq R-enabled-k(INPUTS) = true if PREDECESSOR_CONDITIONS .
eq R-enabled-k(INPUTS) = false [owise] .
crl R(INPUTS) => FALLBACK
  if R-enabled-k(INPUTS) = false /\ REMAINING_CONDITIONS .
```

`Reld`는 source상 앞선 규칙 중 입력 패턴이 겹칠 수 있는 후보를 모아, 그 후보가 모두 적용 불가능한 조건을 만든다. rewrite rule 자체에 `[owise]`를 붙이는 방식이 아니다.

현재 정확히 하나의 선두 `ElsePr` 형태를 요구한다. 선행 규칙의 enabled 조건에 rewrite condition이 필요한 경우에는 이 Boolean complement 경로로 처리하지 못한다. `otherwise`가 임의 관계의 부정을 자동 해결한다는 뜻이 아니다.

### R5. 실행 premise를 포함하는 RuleD

`RulePr` 자체의 일반 번역은 `R(input) => output-pattern`이라는 rewrite condition이다. 그러나 현재 Wasm source에서 실행 premise가 들어 있는 8개 규칙은 모두 `hint(k_heatcool)`로 **4.5절의 heat/cool lowering**을 선택한다. 이 현재 경로를 평범한 `crl ... if Step(...) => ...` 출력으로 잘못 소개하지 않는다.

## 2.4 Type, parameter, argument: 세 가지를 구별하기

구현: [term.ml](../translator/term.ml)의 `translate_sort`, `translate_typ`, `translate_check_typ`, [param.ml](../translator/param.ml).

| 역할 | 예 | 결과 |
| --- | --- | --- |
| Maude 저장 sort 선택 | source `u32` 값 | 주로 `Nat`; 일반 syntax 값은 `SpectecTerminal` |
| source 타입을 값으로 표현 | `VarT("u32",[])` | `App("u32",[]) : SpectecType` |
| 반복까지 보존한 타입 인자 | `TypA(IterT(t,List))` | `iterList(T(t))` |

`Nat`라는 Maude sort만으로 `u32`의 범위가 표현되지는 않는다. source 타입 descriptor와 필요한 `typecheck` 조건은 별도다.

### T1. 타입 패턴별 대응

다음은 source 표기 → IL → Maude **타입 항** 순서다.

| SpecTec | IL | `translate_typ` / 필요한 경우 `translate_check_typ` |
| --- | --- | --- |
| `bool` | `BoolT` | `bool` |
| `nat`, `int`, `rat`, `text` | `NumT ...`, `TextT` | `nat`, `int`, `rat`, `text` |
| `uN(32)` | `VarT("uN", [ExpA 32])` | `uN(32)` |
| parameter `syntax X`의 `X` | `VarT("X",[])` + scope의 `TypP` | `X : SpectecType` 변수 |
| tuple type | `TupT fields` | component별 번역; `translate_typ`에 직접 주면 거부 |
| `t*` | `IterT(t,List)` | 일반 검사에서는 원소 타입 `T(t)`와 sequence 검사; 타입 인자로 전달할 때는 `iterList(T(t))` |
| `t?` | `IterT(t,Opt)` | option 조건; 타입 인자로 전달할 때는 `iterOpt(T(t))` |
| `t+`, `t^n` | `IterT(t,List1/ListN)` | 반복 길이 조건은 지원. **독립적인 타입 값으로 전달하는 경로는 미지원** |

`real` descriptor가 backend에 있다는 것만으로 IL Real literal·산술·변환을 지원한다고 판단하면 안 된다.

### T2. Parameter와 argument

| SpecTec | 선언의 IL / 호출의 IL | Maude 변환 도식 |
| --- | --- | --- |
| 값 인자 `n : nat`, 실제 값 `3` | `ExpP("n", NumT Nat)` / `ExpA(NumE 3)` | domain `Nat` / 항 `3` |
| `syntax X`, 실제 타입 `valtype` | `TypP "X"` / `TypA(VarT("valtype",[]))` | domain `SpectecType` / 항 `valtype` |
| `def $f_(...)`, 실제 함수 `$iadd_` | `DefP(...)` / `DefA "iadd_"` | signature별 `SpectecDef-...` sort / 함수 값 상수 |
| grammar parameter·argument | `GramP` / `GramA` | 현재 미지원 |

함수 값의 실제 source는 [3.2-numerics.vector.spectec](../spectec/wasm-3.0/3.2-numerics.vector.spectec)다.

```spectec
def $ivunop_(shape, def $f_(N, iN(N)) : iN(N), vec_(V128)) : vec_(V128)*
```

IL은 `DefP("f_", ..., result)`를 갖고, body의 `CallE("f_", args)`를 번역할 때 일반 함수 이름 대신 `apply(F, args...)`를 만든다.

```maude
--- 변환 도식
sort SpectecDef-SIGNATURE .
subsort SpectecDef-SIGNATURE < SpectecDef .
op apply : SpectecDef-SIGNATURE ARG-SORTS -> RESULT-SORT .
eq apply(concrete-function, ARGS) = concrete-function(ARGS) .
```

실제 `apply` 선언의 partiality와 sort는 `Param.apply_declaration`을 따른다. 이 도식은 signature 이름과 argument 목록을 생략했다. 임의 OCaml closure를 Maude에 넣는 기능이 아니라 source에서 등장한 함수 값·signature를 선언으로 나타내는 것이다.

## 2.5 Expression과 path: `Term.translate_exp`

입력 [exp'의 30개 constructor](../spectec/lib/il/ast.ml)를 기준으로 읽는다. 아래 표는 **부분식 하나의 변환**이다. enclosing clause의 guard와 변수 선언은 생략한다. `E(e)`는 재귀 번역, `box(e)`는 원소 경계를 지키는 boxing을 뜻한다.

### E1. 원자·연산·조건식

| SpecTec source 조각 | IL AST | Maude 변환 도식 |
| --- | --- | --- |
| `$min(i,j)`의 `i` | `VarE "i"` | prescan이 정한 `I : Nat` |
| `$sum(eps)=0`의 `0` | ``NumE (`Nat 0)`` | `Const "0"` → `0` |
| `true`, `false` | `BoolE b` | `true`, `false` |
| 문자열 이름 | `TextE s` | escape한 Maude 문자열; 비ASCII byte는 3자리 octal escape |
| `~b`, `$(-n)`, `$(+n)` | `UnE(op,ty,e)` | `not E(e)`, `- E(e)`; unary plus는 `E(e)` |
| `$(n + m)`, `b /\ c` | `BinE(op,ty,l,r)` | `E(l) + E(r)`, `_and_(E(l),E(r))` |
| `$(i <= j)` | `CmpE(LeOp,ty,i,j)` | `E(i) <= E(j)` |
| 조건식 자체 — 현재 Wasm 대표 예 없음 | `IfE(c,t,f)` | `if E(c) then E(t) else E(f) fi` |

숫자 literal은 Nat·Int·유한 Rat를 지원한다. `BinE`는 연산과 annotation을 함께 보고 `+`, `-`, `*`, `/`, `rem`, `^` 등을 고른다. source의 `\`/나머지 등을 임의로 host 연산으로 계산해 버리는 단계가 아니다. Real 연산, Rat power 등은 거부한다.

### E2. Constructor·tuple·option

| SpecTec source 조각 | IL AST | Maude 변환 도식 |
| --- | --- | --- |
| `I32` | `CaseE(I32,TupE [])` | `I32` |
| `REF NULL ANY` | `CaseE(REF,TupE [null_opt; any])` | `REF(E(null_opt), ANY)` |
| 타입에 투명하게 포함된 값 | `CaseE(hole-only,TupE [e])` | `E(e)` |
| `mut? storagetype` 같은 unnamed product | `CaseE(hole-only,TupE [a;b])` | `tuple(box(E(a)) box(E(b)))` |
| `$minus_recs` 등의 쌍 결과 | `TupE [a;b]` | `tuple(box(E(a)) box(E(b)))` |
| tuple component 사용 | `ProjE(e,k)` | `(E(e) . k)`를 결과 타입에 따라 unbox |
| 투명 payload를 꺼내는 내부 식 | `UncaseE(e,hole-only)` | `E(e)` |
| 위 투명 case의 단일 component | `ProjE(UncaseE(e,hole-only),0)` | `E(e)` |
| 없는 option / 있는 option | `OptE None` / `OptE(Some e)` | `eps` / `box(E(e)) ?` |
| option 추출 — 현재 지원 예 없음 | `TheE e` | 명시적 미지원 |

이름 있는 `UncaseE`는 일반 expression 위치에서 미지원이다. 반면 constructor **pattern**은 `Prem`이 구조를 매칭할 수 있다. 식을 계산하는 방향과 이미 있는 값을 패턴으로 분해하는 방향은 같지 않다.

### E3. 목록: `ListE`, `CatE`, `MemE`, `LenE`, `IdxE`, `SliceE`, `LiftE`

실제 source 근거는 `$sum`·`$disjoint_`·`$relaxed2`, 그리고 `BR_TABLE`, memory access 규칙이다.

| SpecTec source 조각 | IL AST | 일반 목록의 Maude 변환 도식 |
| --- | --- | --- |
| `eps` | `ListE []` | `eps` |
| `n n'*` | `CatE(ListE[n], tail)` | `N NS` |
| 두 목록의 `++` | `CatE(xs,ys)` | `E(xs) E(ys)` |
| `$disjoint_`의 `w <- w'*` | `MemE(w,ws)` | `E(w) <- E(ws)`; 원소가 목록이면 boxing |
| `|xs|` | `LenE xs` | `len(E(xs))` |
| `$relaxed2`의 `(X_1 X_2)[i]` | `IdxE(ListE[x1;x2],i)` | `(X1 X2) [ I ]` |
| `xs[i:n]` | `SliceE(xs,i,n)` | `XS [ I : N ]`; N은 끝 위치가 아니라 **길이** |
| option을 list 위치에 쓰는 coercion | `LiftE option_exp` | `lift(E(option_exp))` |

정확한 연산 이름은 `Prescan.sequence_representation`에서 가져온다. typed list이면 예를 들어 `instrSize`·`instrOccurs`를 쓴다. 현재 typed list의 `IdxE`, `SliceE`와 해당 path는 미지원이다.

일반 목록은 `[assoc id: eps]`인 `__`를 쓴다. 하지만 목록의 목록은 flatten하면 안 된다.

```text
source의 목록 원소: [ [a,b], [c] ]
Maude 표현 도식:   seq(A B) seq(C)
```

`seq`는 목록 한 덩어리를 `SpectecTerminal` 하나로 만든다. index나 tuple projection이 그 값을 꺼낼 때는 `unseq` 또는 해당 표현의 unbox를 사용한다. 이것이 `$concat_`가 단순 `CatE` 하나와 다른 이유다.

### E4. Record·합성·중첩 경로

실제 source: [2.0-validation.contexts.spectec](../spectec/wasm-3.0/2.0-validation.contexts.spectec)의 `$with_locals`.

```spectec
def $with_locals(C, x_1 x*, lct_1 lct*) =
  $with_locals(C[.LOCALS[x_1] = lct_1], x*, lct*)
```

핵심 path는 다음과 같다.

```ocaml
UpdE (VarE "C",
      IdxP (DotP (RootP, LOCALS), VarE "x_1"),
      VarE "lct_1")
```

**Maude 변환 도식:**

```maude
C [. 'LOCALS = ((C . 'LOCALS) [ X1 = LCT1 ]) ]
```

안쪽 목록을 바꾼 뒤, 바뀐 목록을 다시 바깥 record에 넣는다. 단순히 마지막 index만 출력하면 원래 record를 잃는다.

| SpecTec 조각 | IL AST | Maude 변환 도식 |
| --- | --- | --- |
| `{ALIGN a, OFFSET o}` | `StrE [(ALIGN,a);(OFFSET,o)]` | `{ item('ALIGN,A) ; item('OFFSET,O) }` |
| `s.MEMS` | `DotE(s,MEMS)` | `S . 'MEMS` |
| 두 context의 합성 | `CompE(c1,c2)` | `recordConcat(C1,C2,context)` |
| 목록/option 합성 | `CompE(l,r)`와 타입 정보 | 목록 concat / `optionConcat` |
| root 교체 | `UpdE(e,RootP,r)` | `E(r)` |
| index 교체 | `UpdE(e,IdxP(p,i),r)` | 선택한 parent의 `setAt` 표기 후 parent를 재귀 갱신 |
| slice 교체 | `UpdE(e,SliceP(p,i,n),r)` | parent의 `splice` 표기 후 parent를 재귀 갱신 |
| field 교체 | `UpdE(e,DotP(p,a),r)` | parent record의 field 갱신 후 바깥 재구성 |
| `e[path =.. xs]` | `ExtE(e,p,xs)` | `update(e,p, concat(select(e,p),E(xs)))` |

path constructor는 정확히 `RootP`, `IdxP`, `SliceP`, `DotP` 네 개다. 각각 select와 update 방향으로 재귀한다. 일반 `CompE`는 타입 선언을 따라 합성 가능한지 검사하며, 현재 record 합성은 무인자 `StructT` 선언 범위다.

### E5. 호출·수치 변환·subtyping coercion

| SpecTec 조각 | IL AST | Maude 변환 도식 |
| --- | --- | --- |
| `$sum(n*)` | `CallE("sum",[ExpA ns])` | `sum(NS)` |
| 함수 parameter `$f_(...)` | `CallE` + scope의 `DefP` | `apply(F,ARGS)` |
| 산술에서 elaborator가 넣은 변환 | `CvtE(e,src,dst)` | `E(e) : src <:> dst` |
| `val`을 `instr` 위치에 사용 | `SubE(e,t1,t2)` | 표현 호환 확인 후 `E(e)` |
| `$subst_fieldtype(...)*` | `IterE(body,iterexp)` | 2.7절 |

`SubE`는 무조건 삭제하지 않는다. `Prescan.same_representation`이 허용하는 경우만 항을 그대로 쓴다. 표현을 바꾸는 임의의 subtype adapter는 현재 생성하지 않는다.

## 2.6 Premise와 pattern binding

구현: [prem.ml](../translator/prem.ml). premise 번역의 결과는 단순한 조건 목록이 아니다.

```ocaml
{ conditions : Maude_il.rule_condition list;
  bound : source_variable_set;
  otherwise : bool }
```

`bound`는 “이 지점에서 값을 이미 안다”는 뜻이다. 같은 `x = e`도 `x`를 아는지에 따라 equality 검사 또는 pattern matching이 된다.

### P1. `IfPr`: 확인하는 식과 값을 얻는 식

**SpecTec → IL → Maude 변환 도식:**

| source | IL | 결과 |
| --- | --- | --- |
| `-- if $(i <= j)` | `IfPr(CmpE(LeOp,...))` | `BoolCond(I <= J)` |
| `-- if x = y`, 둘 다 bound | `IfPr(CmpE(EqOp,...))` | Boolean equality 검사 |
| `-- if REC st* = $unroll(...)`, 좌변 미지 | `IfPr(CmpE(EqOp,pattern,call))` | `REC(STS) := unroll(...)`, STS를 bound에 추가 |
| `-- if x <- xs`, 둘 다 bound | `IfPr(MemE(x,xs))` | membership Bool 검사 |
| 위 membership에서 x 미지 | 같은 AST + binding context | 허용된 execution/choice 위치에서 prefix·element·suffix 매칭; 그 밖은 거부 |

실제 [Expand source](../spectec/wasm-3.0/2.1-validation.types.spectec)는 `$unrolldt(deftype) = SUB final? typeuse* comptype`라는 equality를 쓴다. 아래처럼 **계산 결과에서 변수를 얻는** 조건이 된다.

```maude
SUB(FINAL-, TYPEUSE-, COMPTYPE) := unrolldt(DEFTYPE)
```

알 수 없는 인자를 가진 함수 호출을 거꾸로 풀어야 하는 경우에는 4.4절의 `inverse` 계약을 사용한다.

### P2. `LetPr`

**source 수준 역할:** elaboration 과정에서 드러난 binding `pattern = value`. 독립된 surface `let` 예제가 항상 있는 것은 아니다.

**IL AST:**

```ocaml
LetPr (local_quants, pattern, value)
```

**Maude 변환 도식:**

```maude
PATTERN := VALUE /\ LOCAL_TYPE_CONDITIONS
```

structural pattern을 매칭하고 새 변수의 bound 정보를 전달한다. 이미 아는 pattern은 equality 조건으로 정리될 수 있다. 일반적인 함수 역계산과 structural decomposition을 구별한다.

### P3. `RulePr`: relation policy에 따른 호출

| source premise | IL AST 핵심 | Maude 변환 도식 |
| --- | --- | --- |
| `Step: c ~> c'` | `RulePr(Step,[],op,TupE[c;c'])` | `Step(C) => C'` |
| `Expand: dt ~~ ct` | 같은 `RulePr`, equation policy | `CT := Expand(DT)`; CT가 bound면 equality |
| `Num_ok: s |- num : nt` | predicate policy | `Num-ok(S,NUM,NT)`가 true인 조건 |
| backend `check` / `compute` | 같은 `RulePr` | 위 predicate / equation 호출 형태, 본문은 수동 backend |

execution과 compute는 입력이 먼저 bound여야 한다. predicate와 backend check는 **모든 인자**가 bound여야 한다. source의 미지 witness를 Boolean 함수가 알아서 생성하지 않는다.

### P4. `ElsePr`, `IterPr`, `NegPr`

| source | IL | 결과 |
| --- | --- | --- |
| `-- otherwise` | `ElsePr` | enclosing 함수·relation에 넘길 marker; D2/R4 참조 |
| `-- (R: x : y)*` | `IterPr(RulePr(...),(List,G))` | 반복 검사 또는 제한된 출력 수집 helper |
| 부정 premise | `NegPr p` | total한 source-derived complement가 없으므로 거부 |

`x =/= y`는 `CmpE(NeOp,...)`이지 `NegPr`가 아니다. 이를 같은 미지원 기능으로 분류하면 안 된다.

### P5. Premise 순서는 어떻게 다루는가

`translate_prems`는 source 순서대로 방문하되, 입력이 아직 없는 **순수 `IfPr`·`LetPr`**를 잠시 보류했다가 이후 binding을 얻으면 재시도할 수 있다. 다음을 함께 설명해야 정확하다.

- 계산 가능한 순수 조건의 dependency scheduling이 있다. 모든 조건이 문자 그대로 원래 순서로 출력되는 것은 아니다.
- 보류된 조건이 `RulePr`·`IterPr` 같은 barrier를 넘어가야 하면 거부한다.
- rewrite가 필요한 호출은 입력이 이미 있어야 하며, 이를 임의로 순수 조건처럼 이동하지 않는다.
- 일반 `Decd`/`Reld`에도 bound 의존성에 따른 최종 condition 정리가 있다.
- `k_heatcool` 경로는 실행 premise 앞뒤의 조건을 단계별로 보존하도록 `normalize:false`로 body를 만들고 continuation을 나눈다.

이는 실행 가능한 binding 순서를 구성하는 구현이다. 임의의 논리 premise 집합에 대한 완전한 탐색·해결 알고리즘이라고 주장하지 않는다.

## 2.7 Iteration: expression, pattern, premise의 세 방향

구현: [iter.ml](../translator/iter.ml).

### I1. 단순 변수 반복: 원본 목록을 그대로 사용

**SpecTec:** `$sum(n'*)`의 `n'*`.

**IL AST:**

```ocaml
IterE (VarE "n'", (List, [("n'", VarE "n'*")]))
```

**Maude:** `N--`.

identity 조건과 표현이 맞으면 `map-id`를 만들지 않는다. 길이·option 제약이 필요한 pattern 방향은 별도 조건을 유지한다.

### I2. 일반 map과 zip

**SpecTec:** 1.4절의 `$subst_fieldtype(ft,tv*,tu*)*`.

**IL AST:** `IterE(CallE(...), (List, [("ft",fts)]))`.

**Maude 원문 발췌:**

```maude
eq map-subst-fieldtype(TV-3, TU-3, eps) = eps .
eq map-subst-fieldtype(TV-3, TU-3, FT FTS) =
  subst-fieldtype(FT, TV-3, TU-3) map-subst-fieldtype(TV-3, TU-3, FTS) .
```

generator가 여러 개면 각 목록의 head를 **같은 iteration 한 번에서 함께** 소비한다. Cartesian product가 아니다. base case도 모든 generator가 동시에 빈 형태이고, 길이가 다르면 정상 결과를 만들어 주지 않는다.

### I3. `ListN`: 반복 횟수와 index

**SpecTec 실제 조각:** [1.2-syntax.types.spectec](../spectec/wasm-3.0/1.2-syntax.types.spectec), `$subst_all_valtype`의 `(_IDX i)^(i<n)`.

**IL AST:**

```ocaml
IterE (CaseE (mixop("_IDX %"), TupE [VarE "i"]),
       (ListN (VarE "n", Some "i"), []))
```

**Maude 변환 도식:**

```maude
eq make-indexes(0, I) = eps .
eq make-indexes(s(N), I) = -IDX(I) make-indexes(N, s(I)) .
```

실제 helper 이름은 source body와 prescan에서 결정한다. `N`을 하나씩 줄이고 index를 늘린다. index 없는 `ListN(count,None)`이며 generator도 없으면 새 map helper 대신 `repeatSeq(count, boxed-body)` 또는 typed repeat 연산으로 번역한다.

### I4. `Opt`, `List1`

**source 패턴 → IL → Maude 도식:**

- `f(x)?` → `IterE(body,(Opt,[(x,xs)]))` → 빈 option은 `eps`, 있는 option은 `E(body) ?`.
- `f(x)+` → `IterE(body,(List1,G))` → 최초 helper에는 빈 base가 없고, 첫 원소 뒤의 tail helper에만 빈 base를 둔다.
- `*` → `List` → 빈 base와 head/tail 재귀.
- `^n` → `ListN` → 횟수 0의 base와 countdown 재귀, 필요하면 index.

`Opt`·`List`·`List1`에 generator가 없는 일반 `IterE`는 거부한다. source annotation에서 단순히 별표가 보인다고 항상 같은 lowering이 되는 것은 아니다.

### I5. Iteration을 pattern으로 쓰기: projector

**SpecTec 설명용 조각:** 함수 head의 `(x,y)*`.

**IL AST:** `IterE(TupE[x;y],(List,[(x,xs);(y,ys)]))`가 pattern 위치에 있다.

**Maude 변환 도식:**

```text
project([(x1,y1),(x2,y2)]) = ([x1,x2], [y1,y2])
```

source 목록 하나에서 generator 열을 복원한다. `Prem.bind_pattern`과 `Iter.translate_pattern`이 projector를 요청하고 `translate_projector_statements`가 필요한 역방향 helper를 만든다. 임의 함수 body를 뒤집지는 않는다. 구조적으로 분해할 수 있거나 허용된 inverse binding으로 모든 generator가 결정되어야 한다.

### I6. 반복 premise: check와 output collection

**SpecTec 실제 패턴:** [2.4-validation.modules.spectec](../spectec/wasm-3.0/2.4-validation.modules.spectec)의 `(Import_ok: ... import : xt_I)*`.

**IL AST:**

```ocaml
IterPr (RulePr ("Import_ok", [], op, body),
        (List, [("import", imports); ("xt_I", import_types)]))
```

**일반 구현의 Maude 변환 도식:**

```text
모든 generator bound → iterpr-check(CAPTURES, SOURCES) : Bool
출력 generator 하나만 미지 → OUTPUT := iterpr-output(CAPTURES, KNOWN-SOURCES)
```

현재 output collection은 body가 그 하나의 출력을 결정하는 제한된 형태이며, enclosing relation이 helper 요청을 수집해야 한다. 여러 generator가 미지이거나 rewrite condition을 equation helper에 넣어야 하는 모양은 거부된다. `check` helper에는 무조건 `[owise] = false`를 붙이지 않는다.

위 `Module_ok` source 자체는 현재 backend policy 때문에 자동 helper 생성 대상에서 제외된다. 이 예는 **원문에 IterPr가 있다는 증거**이며, `Module_ok` 전체 자동 번역 성공 예가 아니다.

## 2.8 나머지 최상위 패턴과 파일 조립

| IL 패턴 | 현재 처리 |
| --- | --- |
| `RecD defs` | 같은 번역 함수를 각 정의에 재귀 적용하고 결과 연결 |
| `HintD hint` | prescan에서 소비; 일반 정의 번역에서는 빈 statement 목록 |
| `GramD ...` | 현재 일반 정의 번역에서 빈 목록. grammar translator는 제공하지 않음 |
| `ProdD`, `sym` (`VarG` 등) | `GramD`를 번역하지 않으므로 별도 실행 lowering 없음 |

`Def.translate_script`는 일반 정의 외에 함수 값 application, expression iteration, premise iteration, heat/cool, typed list 지원을 모은다. 변수 식별자 정리와 중복 제거 뒤 `bin/spec2maude.ml`이 다음을 조립한다.

```text
types.maude
  SPEC2MAUDE-SORTS + view + SPEC2MAUDE-TYPES
output.maude
  SPEC2MAUDE-GENERATED
```

읽는 순서는 `SPECTEC-TERM → types.maude → SPECTEC-PRETYPE → output.maude → 수동 relation/builtin backend`다. 실제 loading entry는 [semantics.maude](../translator/backend/semantics.maude)다.

# 3. 방법론으로 제시할 재귀 코드

교수님께 제시할 핵심은 **입력 constructor별 재귀적 정의와, 그 정의가 만드는 출력 AST**다. “AI가 생성한 OCaml 파일의 요약”보다 아래 형태로 쓰면 구현을 검토할 수 있다.

```text
translate_script : Il.Ast.script → Maude_il.top_level list
translate_def    : Env → Il.Ast.def → Maude_il.statement list
translate_exp    : Env → Il.Ast.exp → Maude_il.term
translate_prems  : Env → Bound → Il.Ast.prem list → Conditions × Bound × Otherwise
```

실제 `Def.translate_script`는 곧바로 `top_level list` 대신 조립용 `script_translation` record를 반환하고, `bin/spec2maude.ml`이 모듈로 감싼다. 위 첫 signature는 논문에서 전체 변환을 묶은 표기다.

**아래 코드는 설명용 OCaml 의사코드다.** 실제 constructor와 분기 방향을 따르되 record 필드·진단·세부 helper 이름은 줄였다. 그대로 컴파일하는 대체 구현이 아니다. `declare_*`, `bind_*`, `checks`는 설명한 하위 변환을 지칭하며 새로운 의미를 임의로 계산하는 oracle이 아니다.

## 3.1 전체 `def.ml`

```ocaml
let rec translate_def env d =
  match d.it with
  | TypD (id, params, insts) -> translate_typd env id params insts
  | DecD (id, params, result, clauses) ->
      translate_decd env id params result clauses
  | RelD (id, params, op, typ, rules) ->
      translate_reld env id params op typ rules
  | RecD ds -> List.concat_map (translate_def env) ds
  | HintD _ -> []  (* prescan이 이미 읽음 *)
  | GramD _ -> []  (* 현재 구현 경계: grammar 미번역 *)

let translate_script script =
  let env = Prescan.scan script in
  let context_code = translate_heatcool_rules env in
  let ordinary = List.concat_map (translate_def env) script in
  let applications = translate_definition_values env in
  let premise_helpers = translate_requested_iterpr_helpers env in
  let expression_helpers = translate_requested_itere_helpers env in
  assemble_modules
    (normalize (context_code @ ordinary @ applications
                @ expression_helpers @ premise_helpers))
```

실제 ordinary `RelD` 경로에서는 heat/cool로 처리한 `RuleD`를 제외하여 중복 생성하지 않는다. helper가 다시 expression helper를 요청할 수 있으므로 실제 코드의 생성 순서도 확인해야 한다.

## 3.2 `typd.ml`: 타입 선언의 재귀적 정의

```ocaml
let rec translate_typd env id params insts =
  declare_type_operator env id params ::
  List.concat_map (translate_inst env id params) insts

and translate_inst env id params inst =
  match inst.it with
  | InstD (quants, args, body) ->
      let target, guards, bound = translate_type_head env id params args in
      add_guards guards (translate_deftyp env target bound quants body)

and translate_deftyp env target bound quants dt =
  match dt.it with
  | AliasT typ ->
      let v = fresh_value (sort_of_typ env typ) in
      equations_for_alias_and_boxed_alias env v target typ quants
  | StructT fields ->
      let items, conditions = translate_fields env bound fields in
      [conditional_eq (typecheck (record items) target) true_term
         (quant_checks env quants @ conditions)]
      @ record_composition_if_supported env target fields
  | VariantT cases ->
      List.concat_map (translate_case env target bound quants) cases

and translate_case env target bound quants (op, (typ, qs, ps), hints) =
  let values, domains, type_conditions = translate_components env typ in
  let conditions = translate_type_case_prems env bound ps
                   @ quant_checks env (quants @ qs) @ type_conditions in
  if hole_only op then
    [conditional_eq (typecheck (transparent_payload typ values) target)
       true_term conditions]
  else
    let name = constructor_name env op in
    [declare_constructor name domains (constructor_sort env op);
     conditional_eq (typecheck (App (name, values)) target)
       true_term conditions]
```

이 재귀의 근거는 `TypD` 안에 `InstD`가 있고 그 안에 `deftyp`이 있다는 입력의 나무 구조다.

## 3.3 `decd.ml`: 함수와 clause

```ocaml
let translate_decd env id params result clauses =
  let mode = definition_mode env id in
  let header = declare_definition env mode id params result in
  if mode = Builtin || not (body_supported env id) then header
  else
    let prepared = prepare_clause_heads env id params clauses in
    header @ List.concat_map (translate_clause env mode) prepared

let translate_clause env mode prepared =
  let DefD (quants, args, rhs, prems) = prepared.clause.it in
  let lhs, head_guards, initially_bound = prepared.head in
  match mode with
  | Ordinary ->
      let p = translate_prems env initially_bound prems in
      let conditions = schedule_equational_conditions lhs
        (head_guards @ require_no_rewrite p.conditions
         @ necessary_quant_checks env prepared p quants) in
      let attrs = if p.otherwise then [Owise] else [] in
      [eq_or_ceq lhs (translate_exp env rhs) conditions attrs]
  | MembershipChoice -> translate_last_membership_choice env prepared
  | Rule -> translate_rule_clause env prepared (* 4.3절 *)
  | Builtin -> [] (* 본문은 builtins.maude *)
```

`eq_or_ceq`는 조건이 없으면 `Eq`, 있으면 `Ceq`를 고른다. ordinary equation 안에 `RewriteCond`가 들어가면 거부한다. 실제 `prepare_clauses`는 head overlap과 signature를 고려해 불필요한 quantifier 타입 검사를 줄이지만, source premise 자체를 지우는 근거로 사용하지 않는다.

## 3.4 `reld.ml`: relation과 rule

```ocaml
let translate_reld env id params op typ rules =
  match relation_policy env id with
  | Error reason -> []  (* 현재 구현: 5.5절의 한계 *)
  | Ok policy ->
      let header = declare_relation env id params typ policy in
      match policy with
      | BackendCheck | BackendCompute _ -> header
      | Execution _ ->
          header @ lower_execution_rules_in_source_order env id policy
                     (exclude_heatcool_rules env rules)
      | Equation _ | Predicate ->
          header @ List.map (translate_equational_rule env id policy) rules

let lower_rule env id params policy rule =
  let RuleD (label, quants, op, head, prems) = rule.it in
  let components = split_mixop_components op head in
  let inputs, outputs = partition_by_policy policy components in
  let lhs_args, head_conditions, bound = bind_input_patterns env inputs in
  let p = translate_prems env bound prems in
  require_all_bound p.bound outputs;
  { lhs = App (relation_name env id, parameter_terms params @ lhs_args);
    rhs = pack_outputs (List.map (translate_exp env) outputs);
    conditions = head_conditions @ p.conditions @ remaining_quant_checks;
    otherwise = p.otherwise }
```

이 body를 policy별로 감싼다.

```ocaml
Execution → Rl / Crl (lhs, rhs, conditions)
Equation  → Eq / Ceq (lhs, rhs, equation_conditions)
Predicate → Eq / Ceq (lhs, Const "true", equation_conditions)
```

`otherwise`는 R4절의 선행 enabled complement를 먼저 붙여야 한다. heat/cool은 동일한 입력·premise 번역을 바탕으로 4.5절처럼 여러 단계로 나눈다.

## 3.5 `term.ml`: 식의 직접 재귀

식 안의 타입·인자도 같은 환경을 사용해 재귀 번역한다.

```ocaml
let rec translate_arg env arg =
  match arg.it with
  | ExpA e -> translate_exp env e
  | TypA t -> translate_check_typ env t
  | DefA f -> definition_parameter_or_value env f
  | GramA _ -> unsupported "grammar argument"

and translate_typ env typ =
  match typ.it with
  | VarT (x, args) ->
      if is_type_parameter env x then type_variable env x
      else App (type_name env x, List.map (translate_arg env) args)
  | BoolT -> Const "bool"
  | NumT t -> Const (numeric_type_name t)
  | TextT -> Const "text"
  | IterT (element, _) -> translate_typ env element
  | TupT _ -> unsupported "use translate_components"
```

`translate_check_typ`는 타입 인자에 필요한 `iterOpt`·`iterList`를 보존한다.
`Param.translate_sort`는 `ExpP`를 값 sort, `TypP`를 `SpectecType`, `DefP`를
signature별 함수 값 sort로 보낸다. `GramP`는 거부한다.

```ocaml
let rec translate_exp env exp =
  let e = translate_exp env in
  match exp.it with
  | VarE x -> Var (lookup_variable env x exp.note)
  | BoolE b -> Const (string_of_bool b)
  | NumE n -> supported_number n
  | TextE s -> Const (escape_maude_string s)
  | UnE (PlusOp, _, x) -> e x
  | UnE (op, typ, x) -> App (unary_operator op typ, [e x])
  | BinE (op, typ, l, r) -> App (binary_operator op typ, [e l; e r])
  | CmpE (op, typ, l, r) -> App (comparison_operator op typ, [e l; e r])
  | TupE xs -> App ("tuple", [sequence (List.map (boxed_exp env) xs)])
  | ProjE (x, k) -> project_and_unbox env exp.note x k
  | CaseE (op, payload) ->
      if hole_only op then translate_transparent_payload env payload
      else App (constructor_name env op, translate_payload_components env payload)
  | UncaseE (x, op) when hole_only op -> e x
  | UncaseE _ | TheE _ -> unsupported exp
  | OptE None -> Const "eps"
  | OptE (Some x) -> App ("_?", [boxed_exp env x])
  | StrE fields -> record (List.map (translate_field env) fields)
  | DotE (x, a) -> App ("_._", [e x; qid a])
  | CompE (l, r) -> compose_by_declared_type env exp.note (e l) (e r)
  | ListE xs -> sequence_for_type env exp.note (List.map (boxed_exp env) xs)
  | CatE (l, r) -> App (sequence_concat env exp.note, [e l; e r])
  | LenE xs -> App (sequence_size env xs.note, [e xs])
  | MemE (x, xs) -> App (sequence_occurs env xs.note, [boxed_exp env x; e xs])
  | LiftE x -> App (sequence_lift env exp.note, [e x])
  | IdxE (xs, i) -> supported_index_and_unbox env exp.note xs i
  | SliceE (xs, i, n) -> supported_slice env xs i n
  | UpdE (base, p, value) -> update env (e base) p (e value)
  | ExtE (base, p, suffix) ->
      update env (e base) p (concat_at env p (select env (e base) p) (e suffix))
  | IfE (c, t, f) -> App ("if_then_else_fi", [e c; e t; e f])
  | CallE (f, args) -> translate_call_or_apply env f args
  | IterE (body, ie) -> translate_iteration env body ie
  | CvtE (x, src, dst) -> supported_conversion (e x) src dst
  | SubE (x, src, dst) ->
      if same_representation env src dst then e x else unsupported exp
```

실제 `ProjE(UncaseE(...),0)`의 투명 case 최적화도 E2절처럼 별도로 적용한다. `exp.note`는 출력 sort, boxing, 목록 연산, coercion 판정에 쓰이므로 실제 구현에서 버릴 수 없다.

## 3.6 Path의 재귀

```ocaml
let rec select env base path =
  match path.it with
  | RootP -> base
  | IdxP (parent, i) -> index (select env base parent) (translate_exp env i)
  | SliceP (parent, i, n) ->
      slice (select env base parent) (translate_exp env i) (translate_exp env n)
  | DotP (parent, field) -> field_get (select env base parent) field

let rec update env base path replacement =
  match path.it with
  | RootP -> replacement
  | IdxP (parent, i) ->
      let inner = set_at (select env base parent) (translate_exp env i)
                    (box_if_needed env path.note replacement) in
      update env base parent inner
  | SliceP (parent, i, n) ->
      let inner = splice (select env base parent)
                    (translate_exp env i) (translate_exp env n) replacement in
      update env base parent inner
  | DotP (parent, field) ->
      let inner = field_set (select env base parent) field replacement in
      update env base parent inner
```

위 의사코드의 `index`, `slice`, `set_at`, `splice`는 backend operator를 **만드는 함수**다. 번역 시에 source의 실제 목록을 OCaml로 탐색하는 함수가 아니다. 실제 구현은 typed list 미지원 검사와 select 결과의 unboxing도 수행한다.

## 3.7 `prem.ml`: bound를 전달하는 재귀

```ocaml
let rec prems env result deferred remaining =
  match remaining with
  | [] when deferred = [] -> result
  | [] -> unsupported "unresolved pure-premise dependencies"
  | p :: rest ->
      match p.it with
      | IfPr e ->
          attempt_pure env result deferred rest
            (translate_ifpr env result.bound e)
      | LetPr (quants, pattern, value) ->
          attempt_pure env result deferred rest
            (translate_letpr env result.bound quants pattern value)
      | RulePr _ | ElsePr | IterPr _ | NegPr _ ->
          require (deferred = []);
          let next = translate_barrier env result.bound p in
          prems env (append result next) [] rest
```

`attempt_pure`의 핵심은 다음이다.

```text
Ready(조건,새 bound) → 결과에 붙이고 보류했던 순수 조건부터 재시도
Waiting             → 순수 조건만 보류
rewrite 필요 + Waiting 또는 rewrite 경계를 넘는 의존성 → Unsupported
```

`RulePr`의 실제 분기를 논문에 함께 제시하면 Maude 조건 선택이 드러난다.

```ocaml
match policy with
| Predicate | BackendCheck ->
    require_all_inputs_and_outputs_bound ();
    [EqCondition (BoolCond call)]
| Equation _ | BackendCompute _ ->
    require_inputs_bound ();
    if outputs_known then [EqCondition (EqCond (result, call))]
    else bind_output_pattern (MatchCond (pattern, call))
| Execution _ ->
    require_inputs_bound ();
    bind_output_pattern (RewriteCond (call, pattern))
```

## 3.8 `iter.ml`: AST 반복에서 target 재귀 equation 생성

```ocaml
let translate_iteration env body (iter, generators) =
  match identity_source env body (iter, generators) with
  | Some xs -> translate_exp env xs
  | None ->
      match iter, generators with
      | ListN (n, None), [] ->
          App (repeat_operator env body.note,
               [translate_exp env n; boxed_exp env body])
      | (Opt | List | List1), [] -> unsupported "missing generator"
      | _ ->
          request_forward_helper env body;
          App (iteration_name env body,
               capture_terms env body @ iterator_controls iter
               @ List.map (fun (_, xs) -> translate_exp env xs) generators)
```

helper 생성의 일반 `List` 경우는 다음 재귀 equation을 **AST로 구성**한다.

```text
map(CAPTURES, eps, ..., eps) = eps
map(CAPTURES, x1 xs1, ..., xk xsk)
  = box(E(body)) map(CAPTURES, xs1, ..., xsk)
```

option·nonempty·counted iteration은 I4절의 base/step을 사용한다. pattern 방향은 projector를, premise 방향은 check/output helper를 생성한다. 이 세 방향은 하나의 `map` 호출로 뭉개지지 않는다.

## 3.9 논문의 주장과 증명 의무

위 코드로 정의할 수 있는 것은 **구문에 대한 번역 함수**다. 별도로 다음 관계를 정의해야 의미 보존 명제가 된다.

```text
값 대응:       source value v  ↔  Maude representation ⟦v⟧
계산 대응:     source 함수 결과와 target equation의 정상 결과
관계 대응:     source R(inputs,outputs)와 target의 성공한 요청/결과
문맥 대응:     heat/cool 내부 상태를 source 관측 상태로 보내는 대응
```

고정 입력 범위, hint 계약, builtin/backend의 가정, undefined 값과 실패의 표현을 명제에 포함해야 한다. 이 문서의 예제와 재번역 검사는 그 명제를 검토하는 근거이며 보존 증명 자체는 아니다.

# 4. Hint가 선택하는 특수 변환

Hint의 입력 구조는 공통이다.

```ocaml
HintD (TypH (id, hints))
HintD (DecH (id, hints))
HintD (RelH (id, hints))
HintD (RuleH (relation_id, rule_id, hints))
```

각 `hint`의 `hintexp`는 **EL AST**다. 예를 들어 flag는 `El.Ast.SeqE []`, `"check"`는 `El.Ast.TextE "check"`, inverse의 `$g`는 `El.Ast.CallE(g,[])`다. 따라서 hint payload까지 전부 IL expression이라고 설명하면 틀린다.

`show`, `macro`, `desc`, `name`, `prose`, `tabular`는 문서 표기용이다. 현재 이 이름들은 실행 lowering을 고르는 hint가 아니다. 알려진 번역 hint의 형식·충돌은 검사하지만 모든 임의 hint를 의미 있게 처리한다는 뜻은 아니다.

## 4.1 `maude_sort`, `maude_subsort`, `maude_proper`

**SpecTec 실제 발췌:** [instruction syntax](../spectec/wasm-3.0/1.3-syntax.instructions.spectec), [value syntax](../spectec/wasm-3.0/4.0-execution.configurations.spectec).

```spectec
syntax instr hint(desc "instruction") hint(maude_sort) hint(maude_proper "val InstrProper")
syntax val hint(desc "value") hint(maude_sort) hint(maude_subsort "instr") =
  ;; 이하 value case들
```

**IL AST 핵심:**

```ocaml
HintD (TypH ("instr", [flag "maude_sort";
                        text_hint "maude_proper" "val InstrProper"; ...]))
HintD (TypH ("val", [flag "maude_sort";
                      text_hint "maude_subsort" "instr"; ...]))
```

**Maude 원문 발췌:** [types.maude](../translator/generated/types.maude).

```maude
sort val .
sort instr .
sort InstrProper .
subsort val < instr .
subsort instr < SpectecTerminal .
subsort InstrProper < instr .
```

constructor 선언은 owner 정보를 이용해 좁은 codomain을 선택한다. value constructor와 proper instruction constructor를 이름 목록으로 하드코딩하지 않는다.

목록은 현재 `instr`를 root로 native `LIST`를 한 번 instantiate하고, `val` 목록의 좁은 overload·subsort를 연결한다.

```maude
--- 원문의 일부; import renaming의 나머지는 생략
protecting LIST{INSTR-VIEW} * (
  sort List{INSTR-VIEW} to InstrList,
  sort NeList{INSTR-VIEW} to NeInstrList,
  op nil to eps,
  op size to instrSize
) .
subsort ValList < InstrList .
subsort NeValList < NeInstrList .
```

위 import는 일부만 적은 도식이다. 완전한 renaming 목록은 실제 파일을 읽는다. 현재 구현은 서로 관계없는 여러 annotated list family를 일반 지원하지 않는다. 모든 목록 sort가 지원하는 chain을 이뤄야 한다.

**재귀 코드에 추가되는 결정:**

```ocaml
sort_of_typ env typ = Hintd.sort_of_typ env.sort_metadata typ
constructor_sort env op = Hintd.constructor_result_sort env.sort_metadata op
sequence_ops env typ = Hintd.sequence_representation env.sort_metadata typ
```

즉 `LenE`, `CaseE` 등의 AST case를 별도 Wasm 전용 번역기로 교체하지 않고, 재귀 case가 사용할 표현 정보를 바꾼다.

## 4.2 `builtin`과 `maude_kind`: 본문 위임과 partial 선언

### H1. `builtin`

**SpecTec:** [1.0-syntax.profiles.spectec](../spectec/wasm-3.0/1.0-syntax.profiles.spectec)의 `$ND`.

```spectec
def $ND : bool hint(builtin)
```

**IL AST:** `DecD("ND",[],BoolT,...)`와 `HintD(DecH("ND",[flag "builtin"]))`.

**Maude:** translator는 `op nd : -> SpectecTerminal .`을 생성하고, [builtins.maude](../translator/backend/builtins.maude)가 현재 DET profile의 `eq nd = false .`를 제공한다.

```ocaml
if builtin_hint env id then [translate_decl env id params result]
else translate_source_clauses env ...
```

source에서 builtin으로 선언한 numeric 연산·비트 변환·profile 값 등이 이 경로다. backend에 코드가 있다고 모두 번역 실패인 것은 아니다. **`builtin`은 source가 선택한 구현 경계**이고, 5절의 수동 relation 대체와 구별한다.

### H2. `maude_kind`

**SpecTec:** [1.2-syntax.types.spectec](../spectec/wasm-3.0/1.2-syntax.types.spectec).

```spectec
def $IN(N) : Inn hint(maude_kind)
def $IN(32) = I32
def $IN(64) = I64
```

**IL AST:** `DecD("IN",params,Inn,clauses)`와 `HintD(DecH("IN",[flag "maude_kind"]))`.

**Maude 변환 도식:**

```maude
op IN : Nat ~> SpectecTerminal .
eq IN(32) = I32 .
eq IN(64) = I64 .
```

arrow `~>`는 Maude의 partial operator 선언이다. sort에 속하는 결과를 모든 입력에 보장하지 않고 kind 수준의 미계산 항을 허용한다. rewrite rule의 `=>`, SpecTec relation의 `~>`와 다른 문법 역할이다. 이 hint만으로 실패 equation이나 새로운 계산 본문을 만들지 않는다.

## 4.3 `maude_rule`: 함수 본문에 실행이 필요할 때

**SpecTec:** [4.4-execution.modules.spectec](../spectec/wasm-3.0/4.4-execution.modules.spectec).

```spectec
def $evalexprs(state, expr*) : (state, ref*) hint(maude_rule)
def $evalexprs(z, eps) = (z, eps)
def $evalexprs(z, expr expr'*) = (z'', ref ref'*)
  -- Eval_expr: z; expr ~>* z'; ref
  -- if (z'', ref'*) = $evalexprs(z', expr'*)
```

**IL AST 핵심:**

```ocaml
DecD ("evalexprs", params, tuple_result, [
  DefD (...);
  DefD (Q, args, tuple_rhs, [
    RulePr ("Eval_expr", [], op, relation_args);
    IfPr (CmpE (`EqOp, ty, result_pattern, CallE ("evalexprs", recursive_args)))
  ])
])
HintD (DecH ("evalexprs", [flag "maude_rule"]))
```

**Maude 원문 발췌:**

```maude
sort evalexprs-Config .
subsort SpectecTerminal < evalexprs-Config .
op evalexprs : SpectecTerminal SpectecTerminals -> evalexprs-Config [frozen (1 2)] .
rl evalexprs(Z, eps) => tuple(Z seq(eps)) .
crl evalexprs(Z, seq(EXPR) EXPR--) => tuple(Z-- seq(REF2 REF--))
  if Eval-expr(Z, EXPR) => tuple(Z- seq(REF2))
    /\ typecheck(REF2, ref)
    /\ evalexprs(Z-, EXPR--) => tuple(Z-- seq(REF--))
    /\ typecheck(EXPR, expr)
    /\ typecheck(EXPR--, iterList(instr)) .
```

위 코드는 실제 생성물의 발췌다. `expr*`는 instruction의 평탄한 목록이 아니라 expression 목록이므로 각 `EXPR`을 `seq`로 묶는다.

```ocaml
if maude_rule_hint env id then
  declare_request () @ List.map translate_rule_clause clauses
```

`Prem.translate_ifpr`는 rewrite-backed call을 포함하는 **최상위 equality**를 `RewriteCond`로 바꾼다. 임의 expression 안에 이 호출을 중첩하거나 `maude_rule` 함수에서 `ElsePr`를 사용하면 현재 거부한다. 함수 clause의 heat/cool 변환과는 별도 기능이다.

## 4.4 `inverse`: 계산 결과에서 빠진 인자를 구하기

**SpecTec:** [1.2-syntax.types.spectec](../spectec/wasm-3.0/1.2-syntax.types.spectec)의 hint와 signature 발췌.

```spectec
def $isize(Inn) : nat hint(inverse $inv_isize)
def $inv_isize(nat) : Inn hint(maude_kind)
```

**IL AST:**

```ocaml
HintD (DecH ("isize", [
  {hintid = "inverse"; hintexp = El.Ast.CallE ("inv_isize", [])}
]))
(* 사용되는 premise 모양:
   IfPr(CmpE(EqOp, ..., CallE("isize", [ExpA t]), n)) *)
```

**Maude 변환 도식:**

```maude
T := inv-isize(N) /\ isize(T) = N /\ PATTERN_AND_TYPE_GUARDS
```

inverse를 호출한 뒤 얻은 값을 요구된 pattern에 bind하고, forward 호출이 원래 결과와 일치하는지 다시 확인한다. 알려진 인자도 계약에 정한 순서로 전달한다.

```ocaml
match inverse_contract env f with
| ValidInverse {inverse_target; missing} ->
    require_exactly_that_argument_missing ();
    let candidate = call inverse_target (known_args @ [result]) in
    bind_missing_pattern candidate @ [check_forward_call ()]
| InvalidInverse reason -> unsupported reason
```

`inv_concat_`·`inv_concatn_`는 현재 vector/storage source에서 사용하는 폭에 대한 계약을 가진다. 임의 길이의 모든 분할을 열거하는 일반 역관계는 아니다. forward 재확인은 잘못된 후보를 제외하지만, **가능한 모든 후보를 빠짐없이 생성한다는 증명은 아니다.**

## 4.5 `k_heatcool`: 실행 premise를 continuation으로 변환

구현은 [reld.ml](../translator/reld.ml)의 `Context_rules`다. 계약과 전체 8개 예제는 [TRANSLATION.md](TRANSLATION.md#k_heatcool-8개-rule의-변환-예시)에 있고, 여기서는 구조를 이해할 대표 예제를 설명한다.

source 규칙이 다른 실행 relation의 결과를 필요로 하면 내부 request를 실행하고, 저장한 context와 반환값을 조합해 외부 결과를 만든다. **hole은 다음 계산에 필요한 값을 저장하는 continuation**으로 읽으면 된다.

### H3. 실행 premise 하나: `Step/pure`

**SpecTec:** [4.3-execution.instructions.spectec](../spectec/wasm-3.0/4.3-execution.instructions.spectec).

```spectec
rule Step/pure:
  z; instr* ~> z; instr'*
  -- Step_pure: instr* ~> instr'*
  hint(k_heatcool)
```

**IL AST 핵심:**

```ocaml
RuleD ("pure", Q, op_step, TupE [config(z,is); config(z,is')],
  [RulePr ("Step_pure", [], op_pure, TupE [is;is'])])
HintD (RuleH ("Step", "pure", [flag "k_heatcool"]))
```

**Maude 원문 발췌:**

```maude
crl [heating-Step-pure] : Step(Z ; INSTR-) =>
  Step-pure(INSTR-) ~> hole-Step-pure-1(Z)
  if identifyPure(INSTR-) => identified-Step-pure .

eq INSTR-- ~> hole-Step-pure-1(Z) = Z ; INSTR-- .
```

`hole-Step-pure-1`은 나중에 필요한 `Z`를 저장한다. 내부 request가 `INSTR--`로 rewrite되면 cooling equation이 `Z ; INSTR--`를 만든다.

`identifyPure`는 입력 pattern으로 후보를 식별하는 helper다. **모든 premise가 성립함을 미리 증명하는 predicate가 아니다.** 실제 premise는 `Step-pure` 실행에서 검사한다. `identifyRead`도 같은 역할이며, helper 이름은 source rule id에서 정한다.

### H4. 실행 premise 둘: `Steps/trans`

**SpecTec:**

```spectec
rule Steps/trans:
  z; instr* ~>* z''; instr''*
  -- Step: z; instr* ~> z'; instr'*
  -- Steps: z'; instr'* ~>* z''; instr''*
  hint(k_heatcool)
```

**IL AST:** `RuleD(...,[RulePr(Step,...); RulePr(Steps,...)])`와 `RuleH`.

**Maude 원문 발췌:**

```maude
rl [heating-Steps-trans] : Steps(Z ; INSTR-) =>
  Step(Z ; INSTR-) ~> hole-Steps-trans-1 .
eq (Z- ; INSTR--) ~> hole-Steps-trans-1 =
  Steps(Z- ; INSTR--) ~> hole-Steps-trans-2 .
eq (Z-- ; INSTR---) ~> hole-Steps-trans-2 = Z-- ; INSTR--- .
```

첫 번째 실행의 결과로 두 번째 request를 만든다. 두 premise의 binding과 순서가 continuation에 드러난다.

### H5. 중첩 context: `Step/ctxt-label`

**SpecTec:**

```spectec
rule Step/ctxt-label:
  z; (LABEL_ n `{instr_0*} instr*) ~> z'; (LABEL_ n `{instr_0*} instr'*)
  -- Step: z; instr* ~> z'; instr'*
  hint(k_heatcool)
```

**IL AST:** 바깥 `CaseE(LABEL,...)`을 가진 `RuleD`와 body를 실행하는 `RulePr(Step,...)`.

**Maude 원문 발췌:**

```maude
rl [heating-Step-ctxt-label] : Step(Z ; (LABEL- N3 { INSTR-0- } INSTR-)) =>
  Step(Z ; INSTR-) ~> hole-Step-ctxt-label-1(INSTR-0-, N3) .
eq (Z- ; INSTR--) ~> hole-Step-ctxt-label-1(INSTR-0-, N3) =
  Z- ; (LABEL- N3 { INSTR-0- } INSTR--) .
```

hole에는 `instr_0*`와 `n`을 저장한다. 갱신된 `Z-`와 `INSTR--`는 내부 실행에서 반환된다.

### H6. 목록 context: `Step/ctxt-instrs`

**SpecTec:**

```spectec
rule Step/ctxt-instrs:
  z; val* instr* instr_1* ~> z'; val* instr'* instr_1*
  -- Step: z; instr* ~> z'; instr'*
  -- if val* =/= eps \/ instr_1* =/= eps
  hint(k_heatcool)
```

**IL AST:** 목록 concatenation을 포함한 head, 실행 `RulePr`, nonempty `IfPr`, `RuleH`.

**Maude 변환 도식:**

```text
외부 목록 = value-prefix · focus · suffix
후보 focus 식별 + 문맥 경계 조건
  → 내부 Step request와 저장된 prefix/suffix
  → 내부 결과에 prefix/suffix를 다시 연결
```

이 형태는 `Hintd.extract_context`가 식별하는 별도 경로다. 현재 실제 출력은 다음과 같다.

```maude
crl [heating-ctxt-instrs] : Step(Z ; (STACK (OP REST))) => Step(Z ; FOCUS) ~> hole(PREFIX, POSTFIX)
  if (STACK (OP REST)) =/= OP
    /\ identifyFocus(Z, STACK, OP, REST) => { PREFIX | (Z ; FOCUS) | POSTFIX }
    /\ FOCUS =/= (PREFIX (FOCUS POSTFIX)) .
eq (Z- ; INSTR--) ~> hole(PREFIX, POSTFIX) = Z- ; (PREFIX (INSTR-- POSTFIX)) .
```

`identifyFocus`의 후보 rule은 source의 operand·trigger·trailing pattern과 필요한 조건에서 생성된다. 성공 결과 `{ PREFIX | (Z ; FOCUS) | POSTFIX }`를 얻고 내부 `Step`을 실행한 뒤 바깥 목록을 복원한다. `Step(P X S) → Step(X)`만 적으면 복원과 가능한 분해를 설명할 수 없다.

### H7. 일반 heat/cool 의사코드와 지원 경계

```ocaml
let rec resume stage left conditions execution_prems =
  let before, rest = take_conditions_before_next_rewrite conditions in
  match rest, execution_prems with
  | [], [] -> emit_cooling_equation left final_result before
  | RewriteCond (request, result_pattern) :: after, exec :: remaining ->
      let saved = bound_variables_needed_by
                    result_pattern after final_result in
      let hole = declare_hole stage saved in
      emit_suspension left (App ("_~>_", [request; hole])) before;
      resume (stage + 1) (App ("_~>_", [result_pattern; hole])) after remaining
  | _ -> unsupported "execution premise correspondence"
```

실제 코드에서는 최초 suspension은 heating rule이고, 반환 뒤 다음 suspension이나 최종 반환은 equation이다. 실행 premise 앞의 조건은 heating 전에, 뒤의 조건은 결과를 받은 뒤 처리한다.

| 현재 source의 8개 규칙 | 방식 |
| --- | --- |
| `Step/pure`, `Step/read` | 단일 실행과 sequence-result 후보 식별 |
| `Step/ctxt-instrs` | prefix/focus/suffix 추출과 복원 |
| `Step/ctxt-label`, `Step/ctxt-handler`, `Step/ctxt-frame` | 필요한 바깥 값을 hole에 저장한 뒤 재구성 |
| `Steps/trans` | 실행 premise 둘을 순서대로 연결 |
| `Eval_expr` | `Steps` 결과를 받고 source 결과 pattern과 조건 검사 |

continuation 연산의 두 번째 인자는 `[frozen (2)]`로 선언하여 저장한 context 안의 rule rewriting을 막는다. 반환 sort와 request sort도 구별한다. `frozen`은 모든 equational 계산까지 멈춘다는 뜻은 아니다.

현재 `ElsePr`·`IterPr`·`NegPr`가 들어간 hinted rule, rewrite-backed expression은 거부한다. raw request 탐색에는 실패한 내부 가지와 source에 없는 행정 상태가 보일 수 있다. **heating rule 하나를 source Step 하나와 동일시하거나, 이 hint만으로 임의 LTL 속성의 보존을 주장하지 않는다.**

## 4.6 `maude_eq`, `maude_predicate`, `maude_backend`

### H8. `maude_eq`: relation을 출력 계산으로

**SpecTec:** [2.1-validation.types.spectec](../spectec/wasm-3.0/2.1-validation.types.spectec).

```spectec
relation Expand: deftype ~~ comptype hint(maude_eq)
rule Expand: deftype ~~ comptype
  -- if $unrolldt(deftype) = SUB final? typeuse* comptype
```

**IL AST:** `RelD(Expand,...,[RuleD(...,[IfPr equality])])`와 `HintD(RelH(Expand,[flag "maude_eq"]))`.

**Maude 원문 발췌:**

```maude
ceq Expand(DEFTYPE) = COMPTYPE
  if SUB(FINAL-, TYPEUSE-, COMPTYPE) := unrolldt(DEFTYPE)
    /\ len(FINAL-) <= 1 .
```

`~~`의 왼쪽은 입력, 오른쪽은 출력이다. `RuleD` 본문까지 자동 생성한다. rewrite premise가 필요하면 equation 안에 넣을 수 없으므로 거부한다.

### H9. `maude_predicate`: 성공하는 관계를 `true`로

**SpecTec:** [4.1-execution.values.spectec](../spectec/wasm-3.0/4.1-execution.values.spectec).

```spectec
relation Num_ok: store |- num : numtype hint(maude_predicate)
rule Num_ok: s |- CONST nt c : nt
```

**IL AST:** 모든 component를 입력으로 하는 `RelD`/`RuleD`와 `RelH`.

**Maude 원문 발췌:**

```maude
eq Num-ok(S2, CONST(NT, C2), NT) = true .
```

이 경로는 일반적인 `false [owise]`를 생성하지 않는다. 성공 equation이 적용되지 않으면 검사식이 미계산으로 남을 수 있다. **positive predicate 번역**과 **전체 true/false 결정 절차**를 구별한다.

### H10. `maude_backend`: 선언과 호출만 자동 생성

**SpecTec:**

```spectec
relation Ref_ok: store |- ref : reftype hint(maude_backend "check")
relation Module_ok: |- module : moduletype hint(maude_backend "compute")
```

**IL AST:** `HintD(RelH(...,[{hintexp=El.Ast.TextE "check"/"compute";...}]))`.

**Maude 변환 도식:**

```maude
op Ref-ok : SpectecTerminal SpectecTerminal SpectecTerminal -> Bool .
op Module-ok : SpectecTerminal ~> SpectecTerminal .
--- 이 relation들의 source RuleD 본문은 여기서 생성하지 않음
```

```ocaml
match policy with
| BackendCheck | BackendCompute _ -> declarations
| Equation _ | Predicate | Execution _ -> declarations @ translated_rules
```

호출부는 `check`이면 Bool 조건, `compute`이면 계산 결과와의 pattern matching이다. 본문은 [relation-backends.maude](../translator/backend/relation-backends.maude)에 있다. 어떤 의미를 수동 구현했는지는 다음 절에서 설명한다.

# 5. 현재 한계와 relation backend 자동화

## 5.1 수동 구현을 세 종류로 나누어야 한다

| 파일 | 왜 존재하는가 | 자동화 관점 |
| --- | --- | --- |
| [pretype.maude](../translator/backend/pretype.maude) | 목록·option·tuple·record·타입 검사 등 target의 공통 표현과 연산 | `LenE` 등의 번역 결과가 호출하는 공통 target 정의. 모든 내용을 source별로 다시 생성해야 한다는 뜻은 아님 |
| [builtins.maude](../translator/backend/builtins.maude) | source `hint(builtin)`이 선택한 숫자·비트·profile 구현 | source가 명시한 builtin 계약을 구현·검증하는 경계 |
| [relation-backends.maude](../translator/backend/relation-backends.maude) | 현재 자동 `RuleD` 번역을 대신하는 source-specific relation 구현 | 이 절에서 자동화 대상으로 논의하는 부분 |

“backend가 있으므로 IL을 번역하지 못한다”는 표현도, “모든 relation을 재귀적으로 자동 번역했다”는 표현도 현재 경계를 제대로 설명하지 못한다.

## 5.2 정확히 어떤 relation이 수동인가

명시적인 `maude_backend` 대체는 **3개 relation, 그 source 규칙은 합계 16개**다. `check` 두 개만 세면 15개 규칙이다. 내부 helper operator 개수와 relation 개수를 혼동하지 않는다.

| Relation | Hint | source 규칙 | 수동 구현의 현재 역할 |
| --- | --- | --- | --- |
| `Ref_ok` | `"check"` | `null`, `i31`, `struct`, `array`, `func`, `exn`, `host`, `extern`, `sub` — 9개 | reference의 actual type 추출 후 reference/heap subtype 검사 |
| `Externaddr_ok` | `"check"` | `tag`, `global`, `mem`, `table`, `func`, `sub` — 6개 | store의 instance 타입 조회 후 external subtype 검사 |
| `Module_ok` | `"compute"` | `Module_ok` — 1개 | **이미 검증된 모듈**의 closed import/export 타입 계산 |

앞의 두 relation은 [4.1-execution.values.spectec](../spectec/wasm-3.0/4.1-execution.values.spectec), 마지막은 [2.4-validation.modules.spectec](../spectec/wasm-3.0/2.4-validation.modules.spectec)에 있다. 수동 subtype helper는 [2.2-validation.subtyping.spectec](../spectec/wasm-3.0/2.2-validation.subtyping.spectec)의 규칙을 근거로 작성되어 있다. 일반적인 임의 context subtype relation을 모두 자동 생성한 결과는 아니다.

실제로 자동화가 끊기는 지점은 명확하다.

1. `Prescan.classify_relation`이 backend policy를 정한다.
2. `Reld.translate`가 operator 선언만 반환하고 해당 `RuleD` 목록을 번역하지 않는다.
3. `Prescan`은 그 backend relation 소유의 iteration을 helper 생성 목록에서 제외한다.
4. `Prem.translate_rulepr`는 호출 형태만 생성한다.
5. `semantics.maude`가 수동 relation 파일을 로드하여 본문을 연결한다.

## 5.3 왜 단순 재귀 번역만으로 처리하기 어려운가

### L1. `Ref_ok/sub`: ground 입력 안에도 미지 witness가 있다

**SpecTec 원문 발췌:**

```spectec
rule Ref_ok/sub:
  s |- ref : rt
  -- Ref_ok: s |- ref : rt'
  -- Reftype_ok: {} |- rt : OK
  -- Reftype_sub: {} |- rt' <: rt
```

**IL AST 핵심:**

```ocaml
RuleD ("sub", Q, op, TupE [s; ref_value; rt], [
  RulePr ("Ref_ok", [], op, TupE [s; ref_value; rt_prime]);
  RulePr ("Reftype_ok", [], op_ok, ...);
  RulePr ("Reftype_sub", [], op_sub, ...)
])
```

질의 `Ref_ok(s,ref,rt)`의 세 입력을 모두 알아도 첫 premise의 `rt'`는 아직 모른다. 현재 predicate 호출은 모든 component가 bound여야 하므로 이 witness를 만들어 주지 못한다. 같은 relation으로의 재귀와 subtype closure도 있다.

**수동 Maude 원문 발췌:**

```maude
ceq Ref-ok(RO_S, RO_REF, RO_RT) =
    backend-reftype-sub(RO_ACTUAL, RO_RT)
  if RO_ACTUAL := ref-ok-actual-type(RO_S, RO_REF) .
eq Ref-ok(RO_S, RO_REF, RO_RT) = false [owise] .
```

수동 코드는 source derivation을 그대로 탐색하기보다 actual type을 구해 subtype 여부를 판단한다. 자동화하려면 **어떤 허용 입력에서 이 대표 타입과 subtype 검사만으로 모든 source 성공을 대표할 수 있는지**를 설명해야 한다.

source의 `Reftype_ok` 조건도 잊으면 안 된다. 이미 유효한 expected type을 받는다는 입력 가정 또는 helper가 필요한 유효성을 확보한다는 별도 근거가 필요하다. 이 문서는 정상 입력에서의 확정 오답을 제시하지 않는다.

### L2. `Externaddr_ok`: 조회 결과와 subtype witness

**SpecTec 원문 핵심:**

```spectec
rule Externaddr_ok/mem:
  s |- MEM a : MEM meminst.TYPE
  -- if s.MEMS[a] = meminst
```

**IL AST:** `RuleD` 안의 `IfPr(CmpE(EqOp,..., IdxE(DotE(s,MEMS),a), meminst))`.

**수동 Maude의 처리 순서:**

```text
indexDefined(store.MEMS, address)
  → instance := store.MEMS[address]
  → actual_type := MEM instance.TYPE
  → backend-externtype-sub(actual_type, expected_type)
```

조회 binding 자체는 현재 expression·pattern 번역과 가깝다. 어려운 부분은 `/sub`에서 새로 등장하는 `xt'`, expected type의 유효성, 각 external type의 subtype 규칙을 완전한 ground 판정으로 엮는 일이다. 이 relation에 `NegPr`가 있어서 수동화했다고 설명해서는 안 된다.

### L3. `Module_ok`: validation 전체와 타입 계산의 차이

**SpecTec 원문 구조:**

```text
Module_ok의 결론: module : clos_moduletype(C, import_types -> export_types)
premise:
  Types_ok, Import_ok 반복, Tag_ok 반복, Globals_ok,
  Mem_ok/Table_ok/Func_ok/Data_ok/Elem_ok 반복,
  Start_ok, Export_ok 반복, export 이름 disjoint,
  C/C'와 각 타입 목록의 binding
```

**IL AST 핵심:**

```ocaml
RuleD (..., head, [
  RulePr ("Types_ok", ...);
  IterPr (RulePr ("Import_ok", ...), ...);
  (* 여러 validation premise *)
  IterPr (RulePr ("Export_ok", ...), ...);
  IfPr (CallE ("disjoint_", ...));
  (* context와 목록을 결정하는 equality들 *)
])
```

**수동 Maude 변환 도식:**

```maude
ceq Module-ok(MODULE(TYPES, IMPORTS, ..., START, EXPORTS)) =
    IMPORT-TYPES -> EXPORT-TYPES
  if DTS := alloctypes(TYPES)
     /\ IMPORT-TYPES := module-ok-import-types(DTS, IMPORTS)
     /\ COMPONENT-TYPES := ...
     /\ EXPORT-TYPES := module-ok-export-types(..., EXPORTS) .
```

함수 body의 validation, start function의 적합성, export 이름 중복 등의 조건을 모두 다시 검사하는 구현이 아니다. [backend의 주석](../translator/backend/relation-backends.maude)도 prevalidated 범위를 명시하며, 프로그램 ingress의 검증은 [wasm2maude/frontend.ml](../wasm2maude/frontend.ml)에 있다.

구별되는 실제 예를 하나 보면 이해하기 쉽다.

```maude
red in SPEC2MAUDE-RELATION-BACKENDS :
  Module-ok(MODULE(eps, eps, eps, eps, eps, eps,
                   eps, eps, eps, START(0) ?, eps)) .
```

현재 결과는 `eps -> eps`다. 그러나 함수가 하나도 없으므로 source의 `Start_ok`가 요구하는 0번 함수는 없다. 따라서 이것은 **전체 validation relation과의 동등성에 대한 반례**다. 이미 검증된 모듈만 받는 정상 ingress의 버그라고 곧바로 분류하지는 않는다.

## 5.4 어떻게 자동화할 것인가: 미구현 제안

다음은 현재 코드 설명이 아니라 연구·구현 제안이다. 함수 이름이나 Wasm 명령 이름을 하드코딩하는 방향으로 확장하지 않는다.

| 순서 | 자동화할 내용 | 필요한 계약·확인 |
| --- | --- | --- |
| 1 | constructor 분기와 record/index 조회에서 witness가 정해지는 base rule부터 기존 `RuleD` 재귀 번역으로 생성 | 입력/출력 mode, bound 의존성, index 실패, 가능한 결과를 보존 |
| 2 | 내부 witness가 필요한 relation을 출력 생성 가능한 request로 표현하거나, source에서 유도된 결정 절차 계약을 명시 | 임의 witness guessing을 하지 않음. 가능한 출력의 누락·추가를 각각 검사 |
| 3 | `Ref_ok/sub`, `Externaddr_ok/sub`의 actual-type/subtype 축약을 명시적인 계약 아래 생성 | 대표 타입의 충분성, subtype closure, nullable·variance·재귀 타입, 종료 조건 |
| 4 | positive 성공 생성과 별도로 `false`/부정 지원의 조건을 정립 | 모든 대안의 실패를 완전히 판정하며 종료하는 절차. 무조건 `[owise] false`를 추가하는 것으로 대체 불가 |
| 5 | `Module_ok`의 자동화 범위를 선택하고 구현 | 아래 두 명제 중 무엇을 목표로 하는지 먼저 구분 |

`Module_ok`에는 다음 두 목표가 있다.

```text
A. 사전 검증된 모듈의 타입 계산 자동화
   Valid(m)인 범위에서 generated_type(m) = source가 주는 type

B. validation 자체의 자동화
   source에서 Module_ok(m,t)가 유도됨 ↔ target에서 성공하고 t를 반환함
   잘못된 모듈의 거부까지 포함
```

현재 수동 코드를 대체하는 첫 단계로는 A의 범위를 명시하고, 원문 premise에서 어떤 계산이 타입을 결정하는지 추적하는 접근이 현실적이다. B를 주장하려면 `Types_ok`부터 구성요소·instruction validation, 반복 출력과 context 의존성을 끝까지 처리해야 한다. “테스트 모듈들이 이미 valid였다”는 사실로 B를 대신할 수 없다.

검증 입력도 경계를 구별해야 한다. valid/invalid subtype, 없는 address, 잘못된 expected type, 중복 export, 없는 start, body type mismatch가 각각 무엇을 확인하는지 기록한다. 이후 의미 보존 주장에는 source derivation과 target 성공/실패의 양방향 대응이 필요하다.

## 5.5 그 밖의 현재 지원 경계

| 영역 | 현재 사실 |
| --- | --- |
| 미분류 relation | `Reld.translate`의 `Error _ -> []`. 사용되지 않은 unsupported relation이 반드시 즉시 진단되는 것은 아니다. |
| 함수 본문 | 미지원 relation을 직접 premise로 참조하는 함수는 prescan에서 body 미지원으로 표시되고 선언만 남을 수 있다. 그 함수를 실제로 호출하려 하면 `require_definition_body`가 거부한다. |
| grammar | `GramD`는 출력 없음. `GramA`·`GramP` 사용 경로는 미지원. |
| expression | 이름 있는 `UncaseE`, `TheE`, IL Real 값·계산·변환, 일부 Rat 연산 등 미지원. |
| 타입 값 | `List1`·`ListN`의 독립적인 type descriptor 전달은 미지원. 반복 자체와 길이 검사는 별개로 지원. |
| 표현 | 표현이 바뀌는 일반 `SubE`, 다형 record composition, 임의 record field 순서에 대한 검사 등 제한. |
| typed list | index/slice 및 대응 update path, 서로 독립적인 list family 조합에 제한. |
| binding | 일반 existential solver 없음. inverse는 하나의 missing argument 계약, IterPr output은 제한된 한 generator 범위. |
| 부정 | 일반 `NegPr`는 미지원. positive predicate 성공과 완전한 Boolean 판정은 다름. |
| heat/cool | 지원 premise shape와 type/sort 조합에 제한. 내부 상태를 노출한 탐색을 source 탐색과 자동 동일시할 수 없음. |
| builtin profile | 현재 DET의 `ND=false`·relaxed 선택. 전체 nondeterministic Wasm profile 보존으로 확대하지 않음. |

따라서 지원 목록에는 **자동 본문 생성 / 수동 위임 / 명시적 Unsupported / 출력 생략**을 따로 표시해야 한다. 모든 미지원 사례가 풍부한 위치 정보와 함께 동일하게 진단된다고 주장할 수 없다. 일반 정의 번역에서 발생한 `Invalid_argument`는 enclosing 정의 이름과 위치를 붙여 `Unsupported`로 바꾸지만, 모든 사전 수집·생략 경로가 같은 방식은 아니다.

## 5.6 같은 revision의 formal과 실행 계약도 구별한다

[formal IL README][formal-readme]에는 substitution의 capture avoidance, let-premise, recursive subtyping, executable fragment에 관한 미완성 부분이 명시되어 있다. formal reduction의 `STR`·`INJ` 규칙은 타입 premise를 도입하여 검사하는 구조인데, [Language의 type premises 설명][language-premises]은 값 생성 때 이 premise를 검사하지 않는다고 설명한다.

실제 `Il.Ast`도 `LetPr of quant list * exp * exp`인 반면 formal README는 이전 identifier-list 문제를 설명한다. 같은 commit에 있다는 이유만으로 모든 formal 구문·실행 규칙이 현재 OCaml AST와 일대일로 일치한다고 가정하면 안 된다.

현재 translator는 [TRANSLATION.md](TRANSLATION.md)의 계약에 따라 `CaseE`·`StrE` 생성에 임의의 타입 invariant 검사를 주입하지 않는다. formal의 목록 길이·index·slice 등은 의미를 검토하는 근거로 사용하되, source·AST·문서 사이의 불일치를 숨기지 않는다. 이 문서에서 **formal 전체와의 완성된 동등성**을 주장하지 않는 이유다.

# 6. Maude IL

## 6.1 왜 문자열을 바로 반환하지 않는가

구현: [maude_il.ml](../translator/maude/maude_il.ml), [maude_emit.ml](../translator/maude/maude_emit.ml).

`translate_exp`가 문자열을 바로 이어 붙이면 괄호, 변수 충돌, 조건 종류, operator signature를 모두 문자열에서 처리해야 한다. 지금은 target 프로그램의 구조를 OCaml 값으로 만든 뒤 마지막에 출력한다.

```text
SpecTec IL                    Maude IL                      문자열
BinE(AddOp,...,n,CallE(...)) → App("_+_", [Var n; App(...)]) → N + sum(NS)
```

따라서 교수님의 “IL AST를 받아 Maude code를 반환하는 재귀 코드”는 다음 합성으로 설명할 수 있다.

```ocaml
let maude_code_of_il script =
  script |> translate_to_maude_il |> Maude_emit.emit_top_levels
```

중간 AST를 반환하는 재귀 정의도 이 방법론에 해당한다. 출력 문자열까지의 연결을 명시하면 된다.

## 6.2 Term은 세 constructor뿐이다

```ocaml
type term =
  | Var of variable
  | Const of string
  | App of name * term list
```

| Maude 의미 | Maude IL | 출력 예 |
| --- | --- | --- |
| 변수 | `Var {name="N3"; sort="Nat"; origin=Source}` | `N3` |
| literal·고정 토큰 | `Const "0"`, `Const "true"` | `0`, `true` |
| 일반 호출 | `App("sum", [ns])` | `sum(NS)` |
| constructor | `App("REF", [a;b])` | `REF(A,B)` |
| infix/mixfix | `App("_+_", [a;b])` | `A + B` |
| 목록 연결 | `App("_ _", [a;b])` | `A B` |
| record | `App("{_}", [items])` | `{ ... }` |

Maude IL에 `Len`, `If`, `Record`, `List` 전용 term constructor가 따로 있지 않다. 전부 `App`과 연산자 이름으로 표현한다. `Const`는 “이 항이 값이라는 의미론적 증명”을 담는 타입도 아니다.

## 6.3 Variable에는 이름뿐 아니라 정체성이 있다

```ocaml
type variable_origin = Source | Generated of int
type variable = { name : string; sort : string; origin : variable_origin }
```

source 변수는 이름·sort로, generated 변수는 고유 번호로 구별한다. 두 helper가 잠정적으로 모두 `VALUE`라는 이름을 사용해도 서로 다른 generated 변수일 수 있다.

`Def.normalize_variables`는 statement의 변수 사용을 따라 이름 충돌과 sort 충돌을 정리하고 실제 `vars ... : Sort .` 선언을 만든다. 이 단계 덕분에 번역 중 구조적 identity와 최종 예쁜 이름을 구별할 수 있다.

## 6.4 Operator 선언

```ocaml
type arrow = Total | Partial

type op_decl = {
  name : string;
  domain : string list;
  codomain : string;
  arrow : arrow;
  attrs : op_attr list;
}
```

예를 들어 `sum`은 다음과 같다.

```ocaml
OpDecl {
  name = "sum";
  domain = ["SpectecTerminals"];
  codomain = "Nat";
  arrow = Total;
  attrs = [];
}
```

출력은 `op sum : SpectecTerminals -> Nat .`이다. `Partial`은 `~>`로 출력한다. 이름 `Total`은 **Maude 선언의 화살표 선택**이지 모든 source 입력에 대해 계산이 종료하며 값을 낸다는 증명이 아니다.

attribute에는 `Ctor`, `Assoc`, `Comm`, `Ditto`, `Id term`, `Prec n`, `Frozen positions`가 있다. 예를 들어 순서가 중요한 목록에 `Assoc`가 있다고 `Comm`까지 붙는 것은 아니다. `frozen_all n`은 1부터 n까지의 인자를 frozen으로 표시한다.

## 6.5 Condition을 두 종류로 나누는 이유

```ocaml
type eq_condition =
  | EqCond of term * term
  | MatchCond of term * term
  | MembershipCond of term * sort
  | BoolCond of term

type rule_condition =
  | EqCondition of eq_condition
  | RewriteCond of term * term
```

| Maude IL | 출력 | 역할 |
| --- | --- | --- |
| `EqCond(a,b)` | `A = B` | 두 계산 결과의 equality |
| `MatchCond(p,e)` | `P := E` | E를 계산하여 P에 매칭·binding |
| `MembershipCond(e,s)` | `E : S` | Maude sort membership |
| `BoolCond(e)` | `E` | Bool 식이 true인 조건 |
| `RewriteCond(e,p)` | `E => P` | rewrite로 얻은 결과에 matching |

`MembershipCond`는 SpecTec 목록의 `MemE`와 다르다. `MemE`는 목록 포함 여부를 계산하는 **term**이고, `MembershipCond`는 target sort 조건이다.

rewrite condition은 rule 조건에서만 표현된다. 그래서 `Decd`의 일반 `ceq` 본문이나 equation relation이 rewrite condition을 요구하면 명시적으로 거부하거나, source hint로 rule lowering을 선택해야 한다.

## 6.6 Statement와 모듈

| Maude IL statement | 출력 |
| --- | --- |
| `SortDecl`, `SubsortDecl`, `VarDecl` | `sort`, `subsort`, `vars` |
| `OpDecl` | `op ... ->/~> ...` |
| `Mb`, `Cmb` | `mb`, `cmb` |
| `Eq`, `Ceq` | `eq`, `ceq` |
| `Rl`, `Crl` | `rl`, `crl` |

equation attribute는 현재 `Owise`다. rule은 선택적인 label을 가진다. 모듈 수준에는 다음 구조가 있다.

```text
module_expr = 이름 | parameterized instantiation | renaming
import      = Protecting | Including | Extending
module_kind = Functional | System
top_level   = Module | View | Load
```

functional module은 `fmod ... endfm`, system module은 `mod ... endm`으로 출력한다. types와 LIST view, 생성된 rewrite 규칙을 서로 다른 module로 조립할 수 있는 이유다.

## 6.7 예제 하나를 처음부터 끝까지 따라가기

source의 `$sum` 재귀 clause를 다시 보자.

```text
1. SpecTec
   def $sum(n n'*) = $(n + $sum(n'*))

2. SpecTec IL
   DefD(...,
        [ExpA(CatE(ListE[n], tail))],
        BinE(AddOp,NatT,n,CallE(sum,[ExpA tail])),
        [])

3. Prescan
   sum 이름, n/tail sort, identity IterE와 그 owner 등을 등록

4. Decd
   head → sum(N3 N--)
   RHS를 Term.translate_exp로 재귀 번역
   필요한 type 조건과 함께 Ceq 생성

5. Maude IL
   Ceq(App("sum", [App("_ _", [n;ns])]),
       App("_+_", [n; App("sum", [ns])]),
       [BoolCond(typecheck(n,n_type));
        BoolCond(typecheck(ns,nat_type))],
       [])

6. Maude_emit
   ceq sum(N3 N--) = N3 + sum(N--)
     if typecheck(N3, n) /\ typecheck(N--, nat) .
```

이 연결을 기준으로 다른 case도 읽으면 된다. **source의 어떤 구조가 IL에 남고, 어느 재귀 case에서 어떤 target 구조가 되며, 필요한 target 연산은 어디에 정의되어 있는가**를 한 번씩 확인한다.

## 6.8 직접 확인할 코드와 이번 문서의 검증 범위

| 확인하려는 질문 | 읽을 entry point |
| --- | --- |
| 입력 constructor는 무엇인가 | [spectec/lib/il/ast.ml](../spectec/lib/il/ast.ml) |
| 전체 입력에서 무엇을 모으나 | [Prescan.scan](../translator/prescan.ml), [Hintd.scan_sorts](../translator/hintd.ml) |
| syntax는 어떻게 생성되나 | [Typd.translate / translate_deftyp](../translator/typd.ml) |
| 함수 clause는 어떻게 생성되나 | [Decd.translate / translate_equation_clause](../translator/decd.ml) |
| relation은 어떻게 생성되나 | [Reld.translate / lower_rule_body](../translator/reld.ml) |
| expression/path는 어떻게 생성되나 | [Term.translate_exp / translate_update](../translator/term.ml) |
| 새 변수를 어떻게 얻나 | [Prem.bind_pattern / translate_prems](../translator/prem.ml) |
| 반복 helper는 어디에서 생기나 | [Iter.translate_term / translate_all](../translator/iter.ml) |
| 함수 값을 어떻게 호출하나 | [Param.translate_applications](../translator/param.ml) |
| target AST와 출력 규칙은 무엇인가 | [maude_il.ml](../translator/maude/maude_il.ml), [maude_emit.ml](../translator/maude/maude_emit.ml) |
| 생성한 전체 파일은 어디 있나 | [types.maude](../translator/generated/types.maude), [output.maude](../translator/generated/output.maude) |

작성 중 다음을 확인했다.

- `test/spectec_to_maude.sh </dev/null`: **PASS (21 files)**. 현재 translator를 빌드·실행하여 새 생성물이 저장된 두 생성 파일과 일치하는지 검사하고, 수동 backend까지 포함해 Maude를 로드했다. Warning/Advisory 검사도 통과했다.
- 같은 frontend로 대표 타입·함수·rule을 elaboration하고 `Il.Print`로 확인했다. 특히 `consttype`의 펼쳐진 case, `list`·`uN`의 transparent `VariantT`, `$sum`의 `CatE`/identity iteration을 대조했다. 문서의 constructor 표기는 그 결과와 소스를 바탕으로 재구성한 골격이다.
- 수동 relation 경계는 별도 읽기 전용 검토를 받았다. L3의 잘못된 start 예제도 기존 생성물과 backend를 로드해 재현했다. 결과는 `eps -> eps`, 19 rewrites이며 명령·출력은 임시 기록의 `module-boundary.maude`, `module-boundary.log`에 있다.
- 이번 변경은 문서다. 전체 WAST suite, 모든 AST/hint 조합, 임의 입력의 의미 동등성, model-checking 보존 증명은 수행하지 않았다.

기본 재현 명령은 저장소 root에서 다음과 같다. 자세한 설치·실행법은 [ARTIFACT.md](ARTIFACT.md)에 있다.

```sh
test/spectec_to_maude.sh </dev/null
```

추가 기록은 `/private/tmp/spec2maude-walkthrough-20260922/`에 둔다. 임시 경로는 영구 산출물이 아니며, 문서의 기준 revision·source 경로와 위 명령이 재현의 기준이다.

[language]: https://github.com/Wasm-DSL/spectec/blob/acc6e834ff403c82554d081237f327346190ad96/spectec/doc/Language.md
[language-premises]: https://github.com/Wasm-DSL/spectec/blob/acc6e834ff403c82554d081237f327346190ad96/spectec/doc/Language.md#premises
[formal-readme]: https://github.com/Wasm-DSL/spectec/blob/acc6e834ff403c82554d081237f327346190ad96/spectec/doc/semantics/il/README.md
[formal-reduction]: https://github.com/Wasm-DSL/spectec/blob/acc6e834ff403c82554d081237f327346190ad96/spectec/doc/semantics/il/5-reduction.spectec
