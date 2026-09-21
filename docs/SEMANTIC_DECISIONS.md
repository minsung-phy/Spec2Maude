# 실행 계약과 현재 한계

번역 대상은 [고정 revision](../spectec/REVISION)의 `wasm-3.0/*.spectec` 21개를
elaboration해서 얻은 IL AST 전체다. 그 입력의 타입 선언·함수 본문·규칙·premise를
이름 하드코딩 없이 재귀 번역한다. 특정 Wasm 프로그램이나 테스트에서 실행하지
않는다는 이유로 입력 IL의 일부를 삭제하지 않는다.

`ast.ml`에 정의할 수 있는 모든 형태의 임의 SpecTec 명세를 지원하는 것은
현재 목표가 아니다. backend 정리는 입력 IL의 번역과 계산에 필요한 표현·연산을
보존해야 한다. 테스트에서 호출되지 않았다는 사실만으로 미사용 구현으로 판단하지 않는다.
원문의 선언·함수 본문·규칙은 수정하지 않고, 명시적인 번역 hint만 허용한다.

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

## 현재 구현과 미지원 항목

- 일반 목록은 `SpectecTerminals`, `eps`, `__`이고, 목록 원소로 쓰이는 목록은
  `seq(...)`로 구분한다. 별도 목록 sort는 `maude_sort` hint로만 선택한다.
- Wasm IL에서 사용하는 Nat·Int·유한 Rat 계산과 변환은 유지한다.
  Wasm f32/f64는 원문의 `POS/NEG`, `NORM/SUBNORM/INF/NAN` 자료와 builtin으로 처리한다.
- 현재 입력에 없는 IL Real 값·변환·산술, 비유한 Rat 값과 일부 Rat 산술은
  지원하지 않는다. 해당 입력을 추가하면 명시적으로 거부하며, 이를 처리하려면
  해당 AST 번역과 backend의 의미를 함께 검토해야 한다.
- 기준 커밋에 있던 `IfE`의 직접 Maude `if` 번역과 root `UpdE`의 replacement 반환은
  유지한다. 추가 backend helper가 필요 없는 직접 번역이며, `RootP`는 중첩 갱신의
  재귀 종료에도 필요하다.
- 현재 입력에 없는 `TheE`와 현재 번역에서 사용하지 않는 `List1`·`ListN`의
  타입 값 표현은 지원하지 않는다. 대응 backend 연산 `_!`, `iterList1`,
  `iterListN`을 두지 않고, 해당 형태를 번역하려 하면 `Unsupported`로 거부한다.
  실제 입력에서 사용하는 `ListN` 반복과 길이 검사는 유지한다. 입력 범위를
  확장할 때는 필요한 AST 번역과 backend 연산을 함께 추가한다.
- 다형 record 구체 인스턴스 생성과 표현을 바꾸는 중첩 SubE adapter 생성은
  현재 제공하지 않는다. record 합성은 무인자 StructT 선언의 필드 타입을 따라
  번역한다. 타입 검사는 선언 순서의 전체 record를 직접 매칭하며, 임의 record의
  필드 순서 변경·추가를 허용하는 일반 검사는 생성하지 않는다.
  Wasm의 실제 SubE는 기존 표현을 유지한다. 기준 커밋처럼 각 `SubE`에서
  `same_representation`을 확인한다. 중첩 변환용 별도 전체 스캔은 유지하지 않는다.
- 현재 입력을 넘어서는 AST 형태와 hint 조합에는 미지원 분기가 남아 있다.
  Wasm 명세 번역과 실행 테스트의 통과를 임의 SpecTec 명세의 번역 지원으로 확대하지 않는다.

## 검증과 모델체킹의 경계

실행 방법은 [ARTIFACT.md](ARTIFACT.md), hint 책임은
[HINT_CONTRACTS.md](HINT_CONTRACTS.md)에 둔다. PASS, STUCK, TIMEOUT을 구분한다.
official suite 통과만으로 모든 프로그램의 의미 동등성이 증명되는 것은 아니다.

모델체커의 초기화·실행 wrapper와 focus/heat/cool 상태를 source의 한 step과
동일시하지 않는다. 특정 속성을 source로 옮겨 주장하려면 상태 대응, 관측 지점,
내부 step의 발산·deadlock 영향과 탐색 완료 여부를 별도로 확인해야 한다.
현재 checked formal 전체와의 동등성 또는 완성된 보존 증명을 주장하지 않는다.

## 공통 backend와 목록 계산

고정 sort, 타입 표현·검사, 목록·option·tuple·record의 공통 연산은
`translator/backend/pretype.maude` 한 파일에 둔다. 이 파일은 먼저
`SPECTEC-TERM`에서 기본 sort를 선언하고, `generated/types.maude`를 읽은 뒤
`SPECTEC-PRETYPE`에서 공통 연산을 정의한다. `types.maude`의
`SPEC2MAUDE-TYPES`는 source hint별 native LIST instantiation과 좁은 타입
선언을 제공한다. `generated/output.maude`는 `SPECTEC-PRETYPE`을 import하고
source별 목록 subsort 연결과 번역된 정의를 추가한다.

이 순서는 native LIST 뒤에 공통 `eps`, `__` overload를 선언하여 두 연산을
하나의 모듈 확장 관계로 연결한다. 공통 정의를 source마다 생성하지 않으며,
파일 통합을 위해 IL 표현이나 equation의 계산 의미를 바꾸지 않는다.

공유 목록 검사는 `T U TS` 패턴으로 원소가 두 개 이상일 때만 재귀한다.
단일 원소를 조건에서 다시 검사하지 않으며, 별도의 빈 suffix 비교가 필요
없다. 현재 Wasm의 `val < instr` 목록은 `eps`와 `__`를 공유한다.
별도 연결 연산을 생성하는 경로는 제공하지 않으며, 목록 sort들이 하나의
subsort chain을 이루지 않는 hint 조합은 `Unsupported`로 거부한다.

`typecheck`는 `SpectecTerminals`에 속하는 값과 목록을 검사한다. 실패
equation과 option 검사도 sort 변수로 정의한다. kind에만 속하는 미정의 항을
일괄적으로 `false`로 바꾸지 않으며, 이런 항의 검사식은 미계산 상태로 남을 수
있다. 생성된 긍정 검사 조건은 `true`일 때만 성립하므로 미계산 검사도 통과하지
못한다. 검사 결과 자체를 부정하거나 `false`와 비교하는 용도로 확장할 때는
미정의 항의 처리 계약을 별도로 정해야 한다.

`LenE`, `SliceE`, `UpdE` 및 premise/iteration의 IL 번역은 유지한다.
`ListE`는 목록 연결을, `LenE`는 `len` 또는 typed 목록의 size를 직접 사용하므로
별도의 `[TS]`, `|TS|` 표기 wrapper는 제공하지 않는다.
일반 목록의 membership은 `PREFIX T SUFFIX` 매칭과 `[owise]`로 구현한다.
index/setAt은 해당 원소 앞 prefix의 길이를 검사한다. slice/splice는
`S = PREFIX REST`, `REST = MIDDLE SUFFIX`를 순서대로 매칭하고
`len(PREFIX) = N`, `len(MIDDLE) = I`를 검사한다. 따라서 정의역은
`N + I <= len(S)`이고, 빈 slice도 끝 위치까지 허용한다. `seq(...)`는
하나의 원소다. 길이와 위치 조건은 목록의 원소 수를 사용하며, 별도의 cursor나
길이 memo table을 사용하지 않는다.

길이는 `lenAux(S, n) = n + |S|`인 accumulator로 계산하고,
반복 목록은 `N = 2 * (N quo 2) + (N rem 2)`로 구성한다.
이는 Maude prelude LIST의 size/reverse처럼 결과를 집계하거나 구성하는
재귀 equation이다. typed list 연산은 native LIST 정의를 사용하고,
생성 코드는 `eps`, `__` 및 목록 연산의 결과 sort를 좁히는 overload를 선언한다.
size·occurs와 size accumulator는 native 선언이 이미 같은 `Nat`·`NzNat`·`Bool`
결과 sort를 제공하므로 좁은 입력 sort에 대해 중복 선언하지 않는다.

record 조회/갱신은 field를 매칭하고 prefix에 동일 field가 없다는 조건으로
첫 항목을 선택한다. 없는 field의 조회는 eps, 갱신은 끝에 추가한다.
비결정적 membership choice helper는 prefix/선택 원소/suffix 매칭 rule로
가능한 원소를 선택한다. source의 선택 의미, boxing과 frozen 인자를 유지한다.
비트별 논리 연산은 폭/operand 조건을 유지한 native Nat 연산을 사용한다.
CLZ/CTZ와 고정 크기 chunk는 매칭으로 구현하며, 실제 인코딩/누산/반전 등
결과를 구성하는 재귀 계산은 남긴다.

popcount와 bit reverse도 accumulator equation으로 계산한다.
각각 `count + 남은 비트의 1 개수`, `reverse(남은 비트) accumulator`를
불변식으로 갖는다.

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
§4.3(조건과 matching), §4.4(연산자 속성), §4.5.4(owise),
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

목록의 위치를 찾을 때 여러 분해 후보의 prefix 길이를 계산하므로,
긴 메모리 목록에서 실행 비용이 클 수 있다. 현재 메모리 실행에는 이전 구현 대비
큰 성능 regression이 알려져 있다. 결과의 정확성과 실행 비용은 별도로 검증한다.

[language]: https://github.com/Wasm-DSL/spectec/blob/acc6e834ff403c82554d081237f327346190ad96/spectec/doc/Language.md
[type-premises]: https://github.com/Wasm-DSL/spectec/blob/acc6e834ff403c82554d081237f327346190ad96/spectec/doc/Language.md#premises
[formal]: https://github.com/Wasm-DSL/spectec/blob/acc6e834ff403c82554d081237f327346190ad96/spectec/doc/semantics/il/README.md
