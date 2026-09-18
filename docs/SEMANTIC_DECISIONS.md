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

## 공통 backend와 목록 계산

고정 `SpectecTerminals`, `eps`, `__`, `seq`, `unseq` 및 공통 목록
`typecheck` 정의는 `translator/backend/spectec-support/list.maude`에 둔다.
생성되는 `DSL-TYPED-LISTS`는 source hint별 native LIST instantiation과
좁은 타입 선언을 제공하고, `DSL-PRETYPE`은 backend 모듈을 import하고
source별 subsort 연결만 추가한다. 공통 정의를 source마다 생성하지 않는다.

`LenE`, `SliceE`, `UpdE` 및 premise/iteration의 IL 번역은 유지한다.
일반 목록의 membership은 `PREFIX T SUFFIX` 매칭과 `[owise]`로 구현한다.
index/setAt은 해당 원소 앞 prefix의 길이를 검사한다. slice/splice는
`S = PREFIX REST`, `REST = MIDDLE SUFFIX`를 순서대로 매칭하고
`len(PREFIX) = N`, `len(MIDDLE) = I`를 검사한다. 따라서 정의역은
`N + I <= len(S)`이고, 빈 slice도 끝 위치까지 허용한다. `seq(...)`는
하나의 원소다. `take`, `drop`, cursor, 32원소 전개식, len memo는 제거했다.

길이를 세는 `lenAux(S, n)`은 `n + |S|`를 계산하는 equation이며,
Maude prelude LIST의 `$size`와 같은 accumulator 형태다. 반복 목록 생성은
`N = 2 * (N quo 2) + (N rem 2)`를 사용하는 equation을 유지한다.
이 둘은 조회 알고리즘이 아니라 필요한 개수 계산/값 생성이다. 단순히
중첩 호출로 바꾸면 65536원소에서 stack overflow가 발생하므로 재귀를
무조건 제거하거나 한 원소씩 중첩시키지 않는다. typed list의 연산은
중복 equation 없이 native LIST 정의를 사용하고 좁은 overload는 유지한다.

record 조회/갱신은 field를 매칭하고 prefix에 동일 field가 없다는 조건으로
첫 항목을 선택한다. 없는 field의 조회는 eps, 갱신은 끝에 추가한다.
비결정적 membership choice helper는 prefix/선택 원소/suffix 매칭 rule로
가능한 원소를 선택한다. source의 선택 의미, boxing과 frozen 인자를 유지한다.
비트별 논리 연산은 폭/operand 조건을 유지한 native Nat 연산을 사용한다.
CLZ/CTZ와 고정 크기 chunk는 매칭으로 구현하며, 실제 인코딩/누산/반전 등
결과를 구성하는 재귀 계산은 남긴다.

`ipopcnt-bits-aux(B, c)`는 `c + B 안의 1의 개수`,
`irev-bits-aux(B, A)`는 `reverse(B) A`를 계산한다. 각 equation은
이 대응을 유지하며 남은 비트 목록을 줄인다. 공개 unary helper는 각각
0/eps로 시작한다. 이는 prelude LIST의 `$size`/`$reverse`와 같은 방식이며,
비트마다 덧셈/연결을 중첩하는 구현에서 발생한 stack overflow를 피한다.
새 backend helper 이름도 prescan의 예약 이름에 포함한다.

이 대응은 유한 ground canonical source 값의 결과와 정의역에 관한 것이다.
`[owise]` membership/record는 unknown symbolic tail에서 이전의 미평가 term과
다른 결과를 낼 수 있으므로 자유 목록 변수의 narrowing 동등성을 주장하지 않는다.
source rule, IL 반복 의미, 전체 model-checking graph 보존 증명으로 확대하지 않는다.

## Wasm driver의 조회와 결과 검사

run/modelcheck의 `findFunc`, WAST의 `findExport`는 export 앞/뒤를 매칭한다.
prefix에 같은 이름이 없다는 조건은 첫 export를 선택하는 기존 의미를 유지한다.
특히 먼저 나온 동일 이름의 global을 건너뛰어 뒤의 function을 선택하지 않는다.
없는 export와 잘못된 address kind에는 정상 조회 결과를 추가하지 않는다.

WAST instance 환경은 `instances.entry`와 associative `instances.concat`으로
표현한다. identity는 `instances.nil`이며 `comm`은 붙이지 않는다.
`cons(k,v,rest)`와 `entry(k,v) concat encode(rest)`를 대응시키면 기존 순서와
삽입 위치를 보존한다. `findInstance`도 prefix 조건으로 첫 동일 ID를 선택한다.
host-provider와 module-done의 환경 생성은 같은 표현을 사용한다.

`match.any`는 associative alternatives에서 성공하는 pattern 하나를 찾는다.
지원하는 canonical result/pattern에서 기존의 Boolean OR와 같은 존재 조건이며,
성공하는 pattern이 없을 때만 `match.no [owise]`가 적용된다.
`activeFrameDepth`는 `runtimeResults`로 확인한 값 prefix를 건너뛴 뒤 활성
FRAME/LABEL/HANDLER의 body로만 내려간다. 뒤쪽 sibling의 FRAME은 세지 않는다.
`runtimeResults`, 인자/결과의 위치별 비교, import 목록 구성은 모든 원소를
검사하거나 결과를 구성하는 연산이므로 필요한 구조적 재귀를 유지한다.

근거는 [Maude 3.5.1 manual](../reference/manual/Maude3.5.1-manual.pdf)의
§4.3(조건과 matching), §4.4(연산자 속성), §4.9(membership/owise 예제),
§8.3(native NAT), §8.14.1(LIST), 그리고 설치된 3.5.1 prelude의 LIST/NAT
정의다. native MAP으로 치환하지 않는 이유는 중복 key의 의미를 바꾸기 때문이다.

WAST 출력기는 긴 `Seq`를 균형 괄호로 묶어 Maude의 평탄한 associative
구문 분석 비용을 줄인다. 각 말단 그룹은 최대 8개 원소이며 `__`의 결합법칙만
사용한다. 원소 순서, `App`의 인자 경계, 목록 원소를 구분하는 boxing은 유지한다.

WAST command 목록은 AST에서 최대 64개씩 나누어 `inputCommands`와
`script.commands-N`의 비순환 정의로 출력한다. 각 원래 command의 인코딩과
순서는 유지하고 마지막 tail만 `commands.nil`이다. 빈 입력도
`inputCommands = commands.nil`로 출력한다. 모든 정의를 펼친 정상형은
기존의 단일 `commands.cons` 목록과 같다. 이 정의들은 WAST driver에만
추가하며 SpecTec 실행 규칙이나 일반 Wasm run/modelcheck 출력은 바꾸지 않는다.

캐시의 수명과 실험 조건은 [ARTIFACT.md](ARTIFACT.md)의 실행 안내를 따른다.

[language]: https://github.com/Wasm-DSL/spectec/blob/acc6e834ff403c82554d081237f327346190ad96/spectec/doc/Language.md
[type-premises]: https://github.com/Wasm-DSL/spectec/blob/acc6e834ff403c82554d081237f327346190ad96/spectec/doc/Language.md#premises
[formal]: https://github.com/Wasm-DSL/spectec/blob/acc6e834ff403c82554d081237f327346190ad96/spectec/doc/semantics/il/README.md
