# 지원 범위와 hint 계약

Spec2Maude를 Wasm이 아닌 SpecTec에 쓰려는 사람을 위한 문서다. 번역기 OCaml은 고치지 않고, `.spectec`에 hint를 붙이고 builtin Maude 파일을 넘겨서 쓴다.

이 문서의 내용은 번역기 코드(`translator/*.ml`)와 실제 실행에서 뽑았다. 각 항목 끝의 표시는 확인 수준이다.

- **[실행]** 작은 예제를 번역하고 Maude로 돌려 확인했다 (`test/non-wasm/`, `test/non_wasm.sh`).
- **[코드]** 코드를 읽어 확인했고 실행으로는 확인하지 않았다.

## 1. 번역기가 하는 일

입력 spec에 대해 번역기는 둘 중 하나를 한다.

- 번역한다.
- 위치와 이유를 담은 `Unsupported` 진단을 내고 멈춘다.

예외가 하나 있다. 쓰이지 않는 정의 때문에 전체가 막히지 않도록, 아래 세 경우는 **경고만 내고 넘어간다**. 그 정의를 호출하는 곳이 있으면 그때 `Unsupported`로 멈춘다. **[실행]**

- `maude_compute`/`maude_check` hint가 없는, 실행 relation이 아닌 relation.
- 그런 relation을 premise로 쓰는 함수 (선언만 나오고 본문이 없다).
- `maude_array`/`maude_map` 필드를 지원되지 않는 위치에서 레코드 패턴으로 꺼내는 함수 (5절).

## 2. 사용 방법

```sh
dune exec bin/spec2maude.exe -- -o OUT/output.maude --builtins BUILTIN.maude... SPEC.spectec...
```

- `OUT/types.maude`와 `OUT/output.maude`가 생긴다.
- `--builtins`에는 `hint(builtin)` 함수를 구현한 Maude 파일을 넘긴다. 번역기는 그 파일의 `op`/`ops` 선언 이름만 읽어서, 생성하는 이름이 겹치지 않게 한다 (겹치면 `spectec-` 접두사를 붙인다). 이 옵션을 빼면 이름 충돌을 피하지 못한다. **[실행]**
- Maude에서는 `translator/backend/spectec-sorts.maude`, `types.maude`, `translator/backend/spectec-semantics.maude`, `output.maude`, builtin 파일 순서로 load한다.

## 3. 사용자가 보장해야 하는 가정

번역기는 아래를 검사하지 않는다. 어기면 틀린 번역이 나올 수 있다.

| 가정 | 설명 | 확인 |
|---|---|---|
| 처음 넣는 항은 타입이 맞다 | relation과 함수에 넣는 항은 선언된 타입이어야 한다. 예: `syntax v = C nat -- if nat < 10`일 때 `C(11)`을 직접 넣으면 받아들여진다. 실행 중에는 이런 값이 만들어지지 않는다 (만드는 쪽이 조건을 검사한다). | [실행] |
| 실행은 한 step씩 감싼다 | `hint(k_heatcool)` 규칙은 중간 항 `R(..) ~> hole`을 거친다. 실행·모델체킹은 `crl exec(C) => exec(C2) if Step(C) => C2 .`처럼 한 step 전체를 조건으로 감싸서, 중간 항이 상태로 남지 않게 해야 한다 (`wasm2maude/*-runtime.maude`가 이렇게 한다). 감싸지 않고 `search`하면 중간 항이 해로 보인다. | [실행] |
| `maude_disjoint` | 그 함수의 clause는 어떤 입력에도 많아야 하나만 적용된다. | [실행] |
| `maude_assume "R"` | 생략한 premise `R`은 받아들이는 모든 입력에서 성립한다. | [코드] |
| `maude_compute` | 그 relation은 입력마다 출력이 많아야 하나다 (함수적). 규칙마다 등식이 되므로, 아니면 등식이 서로 다른 결과를 낸다. | [코드] |

## 4. hint 목록

번역기가 읽는 hint는 아래 15개뿐이다. 다른 hint(`desc`, `show`, `macro` 등)는 무시한다.

### 타입에 붙이는 것

| hint | 위치 | 하는 일 | 확인 |
|---|---|---|---|
| `maude_sort` | `syntax` | 그 타입에 자기 Maude sort를 준다. 없으면 일반 sort `SpectecTerminal`과 `typecheck` 조건으로 표현한다. 이 타입의 `t*`는 typed list sort가 된다. | [코드] |
| `maude_subsort "u"` | `syntax` | 이 sort를 `u`의 subsort로 선언한다. 양쪽 모두 `maude_sort`가 있어야 한다. | [코드] |
| `maude_array` | 레코드 필드 (`x*`) | 그 필드를 크기와 prelude ARRAY로 저장한다. 값이 0인 칸은 저장하지 않는다. `|e.f|`, `e.f[i]`로 읽는다. | [실행] |
| `maude_map` | 레코드 필드 (`x*`) | 그 필드를 크기와 prelude MAP으로 저장한다. | [실행] |

### 함수에 붙이는 것

| hint | 하는 일 | 확인 |
|---|---|---|
| `builtin` | 본문을 번역하지 않는다. 구현은 `--builtins`로 넘긴 Maude 파일에 같은 이름으로 있어야 한다. | [실행] |
| `maude_kind` | 결과가 없을 수 있는 함수로 선언한다 (부분 함수). | [코드] |
| `maude_rule` | clause를 등식이 아니라 rewrite rule로 번역한다. 실행 relation을 premise로 쓰거나 결과가 여러 개일 수 있는 함수에 쓴다. clause 순서는 지킨다: 뒤 clause는 앞 clause가 안 맞을 때만 적용된다. | [실행] |
| `maude_disjoint` | clause에 "앞 clause가 안 맞을 때"라는 조건을 붙이지 않는다. 3절의 가정이 필요하다. `otherwise` clause가 있으면 거부한다. | [실행] |
| `inverse $g` | `$f(x) = y` 꼴의 premise에서 `y`를 알고 `x`를 모를 때 `$g`를 호출해 `x`를 구한다. | [코드] |
| `maude_assume "R" ...` | 이름 붙인 relation의 premise를 생략한다. 규칙에도 붙일 수 있다. | [코드] |

### relation과 규칙에 붙이는 것

| hint | 위치 | 하는 일 | 확인 |
|---|---|---|---|
| `maude_compute` | relation | 입력에서 출력을 계산하는 등식으로 번역한다. 입력과 출력은 `:` 또는 `~~` 표기 하나로 나뉜다. | [코드] |
| `maude_check` | relation | 성립 여부를 검사하는 등식으로 번역한다. | [코드] |
| `maude_subsume` | `maude_compute` relation의 규칙 | 그 규칙의 결론을 계산과 별도의 검사 연산자로 번역한다. | [코드] |
| `maude_trans "C" ...` | `maude_check` relation의 이행 규칙 | 가운데 항을 나열한 생성자들에서만 찾는다. | [코드] |
| `k_heatcool` | 실행 premise(`~>`, `~>*`)가 있는 규칙 | heating(rule)과 cooling(등식)으로 번역한다. 실행 premise가 있는 규칙에는 반드시 붙인다. | [실행] |
| `k_heatcool "x*"` | 위와 같음 | 추가로 이 규칙을 sequence context로 본다. `x*`는 결론 입력 sequence 안의 변수이고 실행 premise의 입력이어야 한다. relation에 `identifyFocus` 규칙이 생긴다 (6절). | [실행] |

## 5. 지원 범위: 거부되는 모양

실행 relation은 mixop에 `~>` 또는 `~>*`가 있는 relation이다. 그 밖의 relation은 `maude_compute`나 `maude_check`가 있어야 번역된다.

| 모양 | 결과 | 확인 |
|---|---|---|
| `otherwise`와, 아직 값이 정해지지 않은 변수가 있는 `\/`가 한 규칙에 같이 있음 | Unsupported | [실행] |
| 한 relation에서 `k_heatcool` 규칙 뒤에 `otherwise` 규칙이 옴 | Unsupported | [실행] |
| `k_heatcool` 규칙 안의 `otherwise`, 반복 premise | Unsupported | [코드] |
| sequence context가 한 relation에 둘 이상 | Unsupported | [코드] |
| sequence context의 hole 주변이 변수가 아님 (예: `val* x* (FOO y)`) | Unsupported | [코드] |
| hole이 실행 premise의 입력이 아니거나 결론 입력에 없음 | Unsupported | [실행] |
| hole이 든 sequence가 configuration 생성자의 직접 인자가 아님 | Unsupported | [코드] |
| 함수에서 앞 clause가 membership choice(`-- if x <- xs`)이거나 `maude_rule` 함수를 호출하는데, 뒤 clause가 그것과 겹침 | Unsupported (`maude_disjoint`로 해결 가능) | [실행] |
| `maude_array`/`maude_map` 필드를 `m = {F x*}`, `{F x*} = m` premise 밖에서 레코드 패턴으로 꺼냄 | 함수면 경고 후 본문 생략, 규칙이면 Unsupported | [실행] |
| `maude_sort` 타입 둘을 list로 쓰는데 서로 subsort 관계가 아님 | Unsupported | [코드] |
| `maude_compute` relation에 `:`/`~~` 표기가 없거나 둘 이상 | Unsupported | [코드] |
| grammar를 인자로 받는 호출 | Unsupported | [코드] |

이 표는 대표적인 것만 적었다. 번역기에는 이 밖에도 식·패턴 단위의 `Unsupported` 진단이 있다.

## 6. sequence context와 identifyFocus

`hint(k_heatcool "x*")`가 붙은 규칙

```
rule R/ctxt:
  C[l* x* r*]  ~>  C'[l* x'* r*]
  -- R: ...x*... ~> ...x'*...
```

에 대해 번역기는 "sequence 안에서 `R`이 실행할 수 있는 부분"을 찾는 `identifyFocus` 규칙을 만든다.

- **패턴은 규칙마다 하나다.** `R`의 다른 규칙 각각에 대해, 그 규칙의 결론 입력 모양을 sequence 안 어디서든 찾는 rule을 만든다. `identifyFocus(C[l p r]) => {l | C[p] | r}`.
- **조건은 붙이지 않는다.** 패턴은 결론 입력의 모양만 본다. 규칙의 조건은 focus가 실제로 실행될 때 그 규칙이 검사한다. 그래서 `identifyFocus`는 실행할 수 없는 자리도 후보로 낼 수 있고, 그 후보는 실행 단계에서 버려진다 (3절의 "한 step씩 감싼다" 가정). **[실행: Wasm 3.0 테스트 16개와 fib에서 결과가 수정 전과 같음]**
- **bridge.** premise가 다른 실행 relation 하나뿐인 규칙(예: `Step/pure: z; instr* ~> z; instr'*  -- Step_pure: instr* ~> instr'*`)은 결론 입력에 모양이 없다. 이 규칙은 "premise의 relation이 실행되면 이 relation도 실행된다"는 뜻이므로, premise의 relation의 규칙들로 패턴을 만든다. **[코드]**
- **slot의 sort는 context 변수의 타입에서 온다.** 값과 명령어를 번역기가 구분하지 않는다. **[코드]**

## 7. 확인하지 않은 것

- Wasm이 아닌 실제 언어 spec 전체를 번역해 본 적은 없다. 비-Wasm 근거는 `test/non-wasm/`의 작은 예제 10개다.
- [코드] 표시 항목은 실행으로 확인하지 않았다.
- 번역이 원본 의미를 보존한다는 증명은 없다.
