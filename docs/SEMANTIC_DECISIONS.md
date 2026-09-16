# 실행 계약과 현재 한계

주된 검증 입력은 [고정 revision](../spectec/REVISION)의
`wasm-3.0/*.spectec` 21개다. 명시적인 번역 hint 이외의 원문 계산은 바꾸지 않는다.
실제 IL AST를 이름 하드코딩 없이 재귀 번역한다. 동일한 지원 IL과 hint 계약을
쓰는 다른 명세에도 같은 번역을 적용한다. unsupported 입력은 명시적으로 거부한다.

## AST와 참조 문서

- 실제 입력 구조: [lib/il/ast.ml](../spectec/lib/il/ast.ml).
- 실행에 적용하는 언어 계약: 동일 revision의 [Language.md][language].
- 이전에 참조한 formal: 동일 revision의 [doc/semantics/il/][formal].
  이것은 SpecTec으로 작성한 **IL 자체의 명세**이며, Wasm의 실행 규칙 파일이 아니다.
  README에는 substitution, let-premise, recursive subtyping의 TODO와
  일반적으로 실행 불가능한 witness guessing, 미완성 executable fragment가 명시돼 있다.

formal을 전부 무시하거나 AST constructor 이름만으로 의미를 추측하지 않는다.
다만 formal의 별도 검사 체계를 executable Wasm에 자동으로 추가하지 않는다.
원문·AST·언어 설명에 맞는 직접 번역을 우선하고, 불일치는 적용 범위를 확인한다.

## 값 생성과 타입 제약

Language의 [type premises][type-premises]는 값 생성 때 검사하지 않는
불변식이다. 따라서 `CaseE`는 constructor/payload를, `StrE`는 record 필드를
직접 생성한다. record 갱신·합성에도 타입 불변식 검사를 자동 주입하지 않는다.
함수 clause와 relation rule의 실제 `IfPr`, `LetPr`, `RulePr`는 유지한다.
필요한 타입 검사 연산과 validation relation 자체를 삭제한 것은 아니다.

이전에는 formal STR/INJ의 검사를 실행 번역에 적용했다. 그 결과 원본 scalar
shift 호출의 `CaseE : u32`가 큰 i64 count를 builtin에 넘기기 전에 차단했다.
호출부에 modulo를 추가했던 로컬 원문 수정은 철회했다. builtin은 이미 count를
폭으로 정규화하며, translator의 추가 생성 검사를 제거하는 것이 이 문제의 수정이다.

## 지원 범위

- 일반 목록은 `SpectecTerminals`, `eps`, `__`이며 목록 원소로 쓰이는 목록은
  `seq(...)`로 구분한다. typed-list/context 최적화 hint와 구현은 없다.
- Nat·Int·유한 Rat 계산과 변환을 지원한다. Rat 정수 지수는 음수도 처리하며,
  0의 음수 지수는 부분 연산으로 남는다.
- Real은 유한 literal의 정확한 유리수 값, 숫자 변환, 사칙연산, 비교, 정수 지수의
  닫힌 범위에서 `realValue(Rat)`로 표현한다. 실제 IL validator의 Real power는
  Int 지수를 요구한다. 임의 무리수·초월함수·NaN/Inf를 지원한다는 뜻이 아니다.
  Real에서 Int/Nat 변환은 정수성·부호 조건을 검사한다. Real을 포함한 변환을
  역방향 binding pattern으로 푸는 기능은 기존 baseline처럼 Unsupported이다.
- Wasm f32/f64는 원문의 `POS/NEG`, `NORM/SUBNORM/INF/NAN`과 builtin으로 처리한다.
- `IfE`는 직접 Maude `if`로, root `UpdE`는 replacement로 번역한다.
- record 합성은 필드의 적용된 타입을 따라 목록/option/record 합성을 수행한다.
  무인자 StructT에는 선언별 방정식을, 타입 인자가 있는 StructT에는 actual argument를
  치환한 필드의 재귀 번역을 사용한다. 별도 specialization pass는 없다.
  tuple을 record로 추측하여 펼치지 않는다. typecheck는 선언 순서의 전체 record를
  매칭하며 임의 필드 재배치·추가를 허용하는 일반 검사가 아니다.
- `SubE`는 기존 표현을 유지할 수 있는 경우를 처리한다. 표현 변경이 필요한
  pattern을 조용히 통과시키지 않는다. 임의 중첩 adapter 생성은 하지 않는다.
- source premise의 순서와 중복을 보존한다. iteration projector는 source body의
  forward 결과도 재확인한다. `otherwise`는 associative/identity 목록의 빈 overlap도
  고려한다. 이전 rule이 적용 가능하면 fallback이 실행되지 않아야 한다.

## 검증과 모델체킹의 경계

실행 방법은 [ARTIFACT.md](ARTIFACT.md), hint 책임은
[HINT_CONTRACTS.md](HINT_CONTRACTS.md)에 둔다. PASS, STUCK, TIMEOUT을 구분한다.
official suite 통과만으로 모든 프로그램의 의미 동등성이 증명되는 것은 아니다.

모델체커의 초기화·실행 wrapper를 source의 한 step과
동일시하지 않는다. 특정 속성을 source로 옮겨 주장하려면 상태 대응, 관측 지점,
내부 step의 발산·deadlock 영향과 탐색 완료 여부를 별도로 확인해야 한다.
현재 checked formal 전체와의 동등성 또는 완성된 보존 증명을 주장하지 않는다.

## baseline2의 목록 계산과 출력

`baseline2`는 현재 오류 수정을 유지하면서 source의 `maude_sort`,
`maude_subsort`, `maude_proper`, `maude_context` 적용을 제거한다.
일반 목록은 `SpectecTerminals`, `eps`, `__`, `seq(...)`를 사용하고,
context rule은 원문의 premise와 경계 조건을 포함하는 일반 relation으로 번역한다.
번역기의 해당 hint 지원 코드도 제거했으며, 새 입력의 해당 hint는 거부한다.

`len`, `take`, `drop`, `repeatSeq`는 단일 원소/횟수 재귀다. `splice`는
`take(S, n) U drop(S, n + i)`이며 `n + i <= len(S)` 조건을 유지한다.
캐시, cursor, 32개 단위 순회, 압축된 반복 목록은 사용하지 않는다.
범위 밖 slice/update의 부분성과 nested `seq(...)` boxing은 유지한다.

출력기의 균형 괄호와 64개 단위 WAST command 정의는 main과 동일하게 유지한다.
이는 파일 출력/파서 비용을 맞추기 위한 비교 조건이다. 제거 및 유지 항목은
[BASELINE.md](BASELINE.md)에 기록한다. 전체 suite 통과나 의미 보존 증명을
주장하지 않으며, 선택한 작은 회귀 입력과 Maude 로드를 검사한다.

[language]: https://github.com/Wasm-DSL/spectec/blob/acc6e834ff403c82554d081237f327346190ad96/spectec/doc/Language.md
[type-premises]: https://github.com/Wasm-DSL/spectec/blob/acc6e834ff403c82554d081237f327346190ad96/spectec/doc/Language.md#premises
[formal]: https://github.com/Wasm-DSL/spectec/blob/acc6e834ff403c82554d081237f327346190ad96/spectec/doc/semantics/il/README.md
