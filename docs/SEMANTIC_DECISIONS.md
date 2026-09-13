# 실행 계약과 현재 한계

입력은 [고정 revision](../spectec/REVISION)의 `wasm-3.0/*.spectec` 21개다.
원문의 선언·함수 본문·규칙은 수정하지 않고, 명시적인 번역 hint만 허용한다.
해당 입력의 IL AST를 이름 하드코딩 없이 재귀 번역한다. 임의 SpecTec 명세를
지원하기 위한 기능 확장은 현재 범위에 포함하지 않는다.

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

- 일반 목록은 `SpectecTerminals`, `eps`, `__`이고, 목록 원소로 쓰이는 목록은
  `seq(...)`로 구분한다. 별도 목록 sort는 `maude_sort` hint로만 선택한다.
- Wasm IL에서 사용하는 Nat·Int·유한 Rat 계산과 변환은 유지한다.
  Wasm f32/f64는 원문의 `POS/NEG`, `NORM/SUBNORM/INF/NAN` 자료와 builtin으로 처리한다.
- Wasm에서 사용하지 않는 IL Real 특수값·변환·산술, 특수 Rat 산술, Rat/Real 지수
  확장은 철회했다. 이 숫자 입력은 현재 명시적으로 거부한다. 기준 커밋의 일부
  직접 출력 분기도 제한되었으나, 당시 backend의 계산 지원까지 완전했다는 뜻은 아니다.
- 기준 커밋에 있던 `IfE`의 직접 Maude `if` 번역과 root `UpdE`의 replacement 반환은
  유지한다. 현재 Wasm에서 사용하지 않는다는 이유만으로 기존 분기를 삭제하지 않는다.
- 다형 record 구체 인스턴스 생성과 표현을 바꾸는 중첩 SubE adapter 생성은 철회했다.
  record 합성은 무인자 StructT 선언의 필드 타입을 따라 번역한다. 고정 Wasm IL에
  record 폭 변환과 tuple record 필드가 없으므로 타입 검사는 선언 순서의 전체 record를
  직접 매칭한다. 임의 record의 필드 순서 변경·추가를 허용하는 일반 검사는 생성하지 않는다.
  Wasm의 실제 SubE는 기존 표현을 유지한다. 기준 커밋처럼 각 `SubE`에서
  `same_representation`을 확인한다. 중첩 변환용 별도 전체 스캔은 유지하지 않는다.
- 작은 외부 예제는 회귀 원인을 설명하는 자료일 수 있으나, 그 예제를 지원하는 것이
  Wasm translator의 완료 조건은 아니다. 과거 일반화 실험과 철회한 기대값은 외부 기록에 둔다.

## 검증과 모델체킹의 경계

실행 방법은 [ARTIFACT.md](ARTIFACT.md), hint 책임은
[HINT_CONTRACTS.md](HINT_CONTRACTS.md)에 둔다. PASS, STUCK, TIMEOUT을 구분한다.
official suite 통과만으로 모든 프로그램의 의미 동등성이 증명되는 것은 아니다.

모델체커의 초기화·실행 wrapper와 focus/heat/cool 상태를 source의 한 step과
동일시하지 않는다. 특정 속성을 source로 옮겨 주장하려면 상태 대응, 관측 지점,
내부 step의 발산·deadlock 영향과 탐색 완료 여부를 별도로 확인해야 한다.
현재 checked formal 전체와의 동등성 또는 완성된 보존 증명을 주장하지 않는다.

[language]: https://github.com/Wasm-DSL/spectec/blob/acc6e834ff403c82554d081237f327346190ad96/spectec/doc/Language.md
[type-premises]: https://github.com/Wasm-DSL/spectec/blob/acc6e834ff403c82554d081237f327346190ad96/spectec/doc/Language.md#premises
[formal]: https://github.com/Wasm-DSL/spectec/blob/acc6e834ff403c82554d081237f327346190ad96/spectec/doc/semantics/il/README.md
