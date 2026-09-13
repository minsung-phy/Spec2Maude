# Source hints와 handwritten 구현

대상은 [고정 Wasm 원문](../spectec/REVISION)과 그 원문에 붙은 hint다.
hint는 직접 번역하기 어려운 경계를 명시하며, 원문에 없는 계산을 추가하는 허가가 아니다.

## 번역 인터페이스

| Hint | 역할과 적용 조건 |
| --- | --- |
| `maude_sort` | source 타입에 별도 Maude sort와 목록 표현을 부여한다. 없는 경우 일반 `SpectecTerminals` 표현을 사용한다. |
| `maude_subsort "T"` | 표시된 source 타입 사이의 subsort 관계. 잘못된 대상·cycle을 거부한다. |
| `maude_proper "V P"` | 선언된 constructor 집합에서 값 V를 제외한 proper sort P를 만든다. instruction 이름을 하드코딩하지 않는다. |
| `maude_context` | source context rule을 focus/heat/cool로 번역한다. frame·prefix·hole·postfix를 원문에서 추출하며 실제 premise를 유지한다. |
| `maude_kind` | 함수의 결과를 partial 화살표 `~>`로 선언한다. 이 hint가 없는 일반 함수는 `->`로 선언한다. |
| `maude_rule` | rewrite premise가 필요한 함수를 request/rule로 번역한다. source 결과와 가능한 분기를 유지한다. |
| `inverse $g` | 빠진 인자를 선언된 역함수 g로 구하고 pattern과 forward 결과를 재확인한다. 인자 순서·signature를 검사한다. |
| `builtin` | 함수 선언을 생성하고 `translator/backend/builtins.maude`의 handwritten 구현에 연결한다. |
| `maude_eq` | 계산 가능한 `~~` relation의 입력·출력을 equation으로 대응시킨다. |
| `maude_predicate` | 모든 인자가 알려진 relation을 Boolean predicate로 대응시킨다. |
| `maude_backend "check"` | ground relation의 Bool 검사를 `relation-backends.maude`에 맡긴다. |
| `maude_backend "compute"` | relation의 출력 계산을 `relation-backends.maude`에 맡긴다. |

`show`, `macro`, `desc`, `name`, `prose`, `tabular`는 문서 표현용이며 실행 방식을
선택하지 않는다. hint의 형식 검사가 통과했다는 것과 handwritten 구현이 정확하다는
것은 별개의 검사다. source 함수·규칙을 미사용이라는 이유로 삭제하지 않는다.

## Wasm에서의 적용 범위

- `inv_concat_`는 실제 vector 원문의 `(j_1 j_2)*`를 두 원소씩 복원한다.
  `inv_concatn_`는 storage에서 정한 양수 byte 폭으로 복원한다.
  임의 길이 목록의 모든 분할을 찾는 역관계로 확장하지 않는다.
- `$fbits_`의 `inverse` 대상은 `$inv_fbits_`다. 기존의 `$inv_ibits_` 표기는
  로컬 hint 수정으로 바로잡았다. 함수의 계산식은 변경하지 않는다.
- `Module_ok` backend는 이미 검증된 모듈의 타입 계산 범위다.
  validation relation은 실제 실행 rule의 premise에 요구될 때 연결한다.
- `Ref_ok`, `Externaddr_ok`와 subtype의 handwritten 구현은 원문의 관계를 따른다.
  정상적인 trap과 잘못된 import의 거부를 성공한 실행으로 바꾸지 않는다.

## 숫자 builtin과 profile

Wasm f32/f64·bits·bytes·rounding은 원문 `hint(builtin)` 구현의 책임이다.
IL의 미사용 Real 확장을 제거하는 것과 Wasm 부동소수점 지원을 제거하는 것은 다르다.
숫자 builtin은 해당 revision의 Wasm numeric 정의와 비교한다.

현재 profile은 `ND=false`, relaxed 선택 0인 Wasm DET이다. 산술 NaN 생성과
부호/payload를 보존하는 negate·abs·copysign·reinterpret를 구분한다.
memory/table grow의 자원 실패 선택은 남는다. DET의 결과를 full profile의 모든
NaN·relaxed 선택에 대한 결과로 일반화하지 않는다.

`otherwise`는 source의 앞선 적용 가능한 규칙이 없다는 조건을 보존해야 한다.
context의 내부 상태는 source 상태와 구분한다. 검색 결과 일치는 임의 LTL 속성의
보존 증명이 아니며, 현재 경계는 [실행 계약](SEMANTIC_DECISIONS.md)에 기록한다.
