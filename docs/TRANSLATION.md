# 번역 의미, source hints와 지원 범위

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

- 일반 목록은 prelude `LIST{SpectecTerminal}`(sort `SpectecTerminals`, `nil`, `__`)이고,
  목록 원소로 쓰이는 목록은 `seq(...)`로 구분한다. 별도 목록 sort는 `maude_sort` hint로만 선택한다.
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
- relation 전제에서 어떤 입력에도 묶이지 않은 변수 i가 알려진 `xs[i]`의 인덱스로만
  쓰이면, i는 xs의 유효한 위치를 고른다(`xs[i]`는 i < |xs|일 때만 정의된다):
  `PREFIX E SUFFIX := xs /\ I := |PREFIX|`. 예: `Deftype_sub/super`의 `typeuse*[i]`.
  `maude_check` rule의 결론 입력이 pattern이 아니면(예: `Heaptype_sub/rec-sub`의
  `typeuse*[j]`), 전제가 변수를 묶은 뒤 그 값과 비교한다.
  생성자가 없는 `e?{}` pattern은 eps 또는 e와 같다(예: `Reftype_sub/null`의 `NULL?`).
- 함수 인자(`DefP`/`DefA`)는 번역 전에 함수별 정의로 specialization한다
  (`Def.specialize_script`, `Decd.specialize`). `$g(..., def $t, ...)` 호출마다
  `$g`의 복사본 `$gt`를 만들고 본문의 def 파라미터 이름을 `$t`로 바꾼다(source 의미
  `$g_t(xs) = $g(xs)`, f := t). 호출되지 않는 고차 정의는 출력하지 않는다.
  받은 함수를 다시 넘기는 경우(같은 함수를 넘기는 재귀 포함), def 파라미터를 받는
  def 파라미터, DecD 호출 밖의 `DefA`, TypD/RelD/GramD의 `DefP`, 고차 정의의
  `builtin`/`maude_kind`/`maude_rule`/`inverse` hint, 복사본 이름 충돌은
  `Unsupported`로 거부한다.
- `#` 표현의 미지원 형태: 한 family 안에서 instance마다 같은 생성자의 인자가 native
  여부가 다르면 거부한다. 고차 정의를 대상으로 하는 다른 def의 `hint(inverse ...)`는
  검사하지 않는다. text 값의 연결은 목록 연결로 번역되며 현재 입력에는 없다.
  wasm2maude 인코더는 `#` 위치를 Wasm 구조에 맞춰 직접 정하므로 semantics의
  sort가 바뀌면 함께 고친다.
- 현재 입력을 넘어서는 AST 형태와 hint 조합에는 미지원 분기가 남아 있다.
  Wasm 명세 번역과 실행 테스트의 통과를 임의 SpecTec 명세의 번역 지원으로 확대하지 않는다.

## 검증과 모델체킹의 경계

설치와 실행 방법은 [ARTIFACT.md](ARTIFACT.md)에 둔다. hint 계약은 아래에
기록한다. PASS, STUCK, TIMEOUT을 구분한다.
official suite 통과만으로 모든 프로그램의 의미 동등성이 증명되는 것은 아니다.

모델체커의 초기화·실행 wrapper와 focus/split/plug 중간 상태를 source의 한 step과
동일시하지 않는다. 특정 속성을 source로 옮겨 주장하려면 상태 대응, 관측 지점,
내부 step의 발산·deadlock 영향과 탐색 완료 여부를 별도로 확인해야 한다.
현재 checked formal 전체와의 동등성 또는 완성된 보존 증명을 주장하지 않는다.

### import 범위 (결정, 2026-10-03)

`run`, `modelcheck`, `instantiate`, `harness`는 import가 있는 모듈을 Unsupported로
거부한다(`wasm2maude/emit.ml`). 결과 집계에서도 PASS가 아니라 Unsupported로 센다.
`$instantiate`는 `maude_assume "Module_ok" "Externaddr_ok"`이다.

- 이유: import가 있는 프로그램을 실행·모델체킹하려면 import를 제공하는 쪽이
  필요하다. 예를 들어 `(import "env" "print" (func (param i32)))`의 몸체는 host에
  있고 SpecTec 명세에는 없다. 필요한 일은 ① 제공자(다른 Wasm 모듈 또는 host 함수
  모델)와 ② 제공된 것의 타입 검사(`Externaddr_ok`) 두 가지다. ①이 없으면 ②만
  번역해도 실행할 수 없으므로, import 지원은 ①과 함께 하는 별도 작업이다.
- import가 없으면 `$instantiate`의 두 전제를 생략해도 의미가 그대로다.
  `Module_ok`가 내는 `xt_I*`가 비고 `externaddr*`도 `eps`이므로
  `(Externaddr_ok: s |- externaddr : xt_I)*`는 빈 반복이다. 이 등가는
  import가 없을 때만 성립하므로 wasm2maude의 거부가 그 전제 조건을 보장한다.
  `Module_ok`의 타입 검사는 frontend validator가 보장한다고 가정한다.
- 나중에 import를 지원할 때: 링크 단계에서 frontend(reference interpreter의
  linker)가 import 타입을 검사하면, `Module_ok`와 같은 논리로 `Externaddr_ok`도
  가정으로 둘 수 있다. 그러면 `Externtype_sub` 아래의 validation relation을
  번역하지 않아도 된다. 이 경우에는 frontend 검사와 명세 relation이 같다는 가정을 기록한다.
- wast harness는 이미 이 방식이다. 계획 단계에서 reference interpreter의
  `Wasm.Match.match_externtype`이 import 타입을 검사하고(`wasm2maude/wast_plan.ml`),
  memory/table의 현재 최소 크기 조건만 Maude의 `linkImports`가 실행 중에 검사한다
  (`wasm2maude/wast-runtime.maude`). 따라서 wast의 import 모듈은 frontend linker가
  `Externaddr_ok`와 같은 판정을 한다는 가정 아래 지원된다.

### 호출 인자 검사

`$invoke`의 `(Val_ok: s |- val : t_1)*`가 인자 개수와 타입을 검사한다. wasm2maude는
export가 함수인지까지만 확인한다. `Val_ok`가 실패하면 `$invoke`는 정의되지 않으며,
`run`/`modelcheck` runtime은 `invalid-invocation` 상태로 끝난다. 이 상태에서는
아무 값도 반환되지 않으므로 `[]~ returned(rejected)` 같은 안전성 질의는 공허하게
참이 된다. 먼저 `rewrite` 결과가 `invalid-invocation`이 아닌지 확인한다.

## 공통 backend와 목록 계산

공통 backend의 진입점은 `translator/backend/spectec-semantics.maude`다.
먼저 `spectec-sorts.maude`의 `SPECTEC-SORTS`에서 공통 sort를 선언하고,
`generated/types.maude`를 읽은 뒤 `spectec-builtin-types.maude`의
`SPECTEC-BUILTIN-TYPES`에서 SpecTec 기본 타입(`bool nat int rat real text`)의
Maude 표현, 즉 native import·타입 태그·기본 검사를 선언한다. 이 표현은 IL
연산의 의미가 아니라 표현 선택이므로 의미 모듈과 다른 파일에 둔다.

기본 타입은 IMP처럼 생성자로 감싼다(`op #_ : Bool|Rat|Float|String ->
SpectecTerminal [ctor]`). native sort를 `SpectecTerminal`의 subsort로 두지 않으므로
prelude의 같은 이름 연산이 한 kind에서 충돌하지 않고 import renaming이 필요 없다.
IL `nat`/`int` 값은 native `Nat`/`Int`, 그 밖의 값은 `SpectecTerminal`로 표현한다.
번역기는 값의 sort와 자리가 기대하는 sort가 다를 때만 `#`를 넣거나 뺀다
(`Iter.coerce`): native 값이 목록·option·tuple 원소, 생성자·def 인자, record 필드,
`typecheck` 대상에 들어가면 `# V`, 꺼낼 때는 패턴이면 `# V` 매칭, 식 중간이면
부분 함수 `#rat`/`#bool`/`#string`을 쓴다. 비교·논리 연산 결과는 native이므로
값 자리에서 감싸고, 산술·비교 피연산자는 native로 꺼낸다. CvtE는 native `Rat`을
받고 돌려준다. 생성자 인자 sort는 `CaseE`가 속한 variant 타입의 선언에서,
def 호출 결과는 callee가 선언한 결과 sort에서 정한다.

기능별 연산은 `spectec-semantics.maude` 파일 안의 다음 모듈에 둔다.

| 모듈 | 내용 |
|---|---|
| `SPECTEC-CONVERT` | 수치 타입 변환 |
| `SPECTEC-LIST` | 목록 표현·검사·연산 |
| `SPECTEC-OPTION` | option 표현·검사·연산 |
| `SPECTEC-TUPLE` | tuple 표현·projection |
| `SPECTEC-RECORD` | record 표현·조회·갱신 |
| `SPECTEC-ARRAY` | `hint(maude_array)` 필드의 크기 + prelude `ARRAY` 표현·연산 |

convert와 list는 builtin types를, option·tuple·record·array는 list를 import한다.
마지막 `SPECTEC-SEMANTICS`가 여섯 모듈을 모은다. 공통 목록은
`spectec-sorts.maude`가 prelude `LIST{SpectecTerminal}`을 sort 이름만 바꿔
가져온 것이다(`nil`, `__`, `size`, `occurs`, `append`는 prelude 이름 그대로).
`types.maude`의 `SPEC2MAUDE-TYPES`는 hint별 목록 sort를 이 목록 위에 subsort로
얹고 `nil`, `__`만 좁은 sort로 overload한다(LIST를 다시 instantiate하지 않는다).
`generated/output.maude`는 `SPECTEC-SEMANTICS`를 import하고 번역된 정의를
추가한다.

LIST instance가 하나이므로 typed list의 `nil`, `__`, `size`, `occurs`는 모두 같은
prelude 연산이고 warning·advisory 없이 load된다. prelude 연산 이름(`nil`,
`size`, `occurs` 등)은 `Prescan.reserved_names`에 있어서, 같은 이름의 source
정의는 `spectec-` 접두사를 받는다(예: Wasm `$size` → `spectec-size`).

비어 있지 않은 목록은 prelude `LIST`처럼 `SpectecNeTerminals` sort로 구분한다
(`SpectecTerminal < SpectecNeTerminals < SpectecTerminals`). 공유 목록 검사는
`typecheck(T NTS, TYPE)`로 원소가 두 개 이상일 때만 재귀하고, 빈 목록은 `t*`의
올바른 값이므로 `typecheck(nil, TYPE) = true`를 유지한다. typed list root마다
`NeXList < SpectecNeTerminals`를 함께 생성한다. 현재 Wasm의 `val < instr` 목록은 `nil`과 `__`를 공유한다.
별도 연결 연산을 생성하는 경로는 제공하지 않으며, 목록 sort들이 하나의
subsort chain을 이루지 않는 hint 조합은 `Unsupported`로 거부한다.

`typecheck`는 `SpectecTerminals`에 속하는 값과 목록을 검사한다. 실패
equation과 option 검사도 sort 변수로 정의한다. kind에만 속하는 미정의 항을
일괄적으로 `false`로 바꾸지 않으며, 이런 항의 검사식은 미계산 상태로 남을 수
있다. 생성된 긍정 검사 조건은 `true`일 때만 성립하므로 미계산 검사도 통과하지
못한다. 검사 결과 자체를 부정하거나 `false`와 비교하는 용도로 확장할 때는
미정의 항의 처리 계약을 별도로 정해야 한다.

`LenE`, `SliceE`, `UpdE` 및 premise/iteration의 IL 번역은 유지한다.
`ListE`는 목록 연결을, `LenE`는 prelude `size`를 직접 사용하므로
별도의 `[TS]`, `|TS|` 표기 wrapper는 제공하지 않는다.
membership(`MemE`)은 prelude `occurs`를 사용한다.
index, slice, 원소 갱신, 구간 갱신은 prelude `occurs`처럼 앞 원소를 하나씩 떼는
구조 재귀로 정의한다(`(T TS)[(s N)] = TS[N]`, `(T TS)[(s N) = K] = T TS[N = K]`).
slice/splice는 시작 위치까지 넘긴 뒤 `COUNT`개를 가져오거나 버린다. 따라서
정의역은 `N + COUNT <= size(S)`이고, 빈 slice도 끝 위치까지 허용한다. 범위 밖이면
equation이 적용되지 않아 정의되지 않는다. `seq(...)`는 하나의 원소다.
갱신과 slice의 가져오기 부분은 꼬리 재귀가 아니어서 위치(개수)에 비례하는 stack을
쓴다(64MB stack에서 약 26만 칸까지 확인, 52만 칸에서 overflow).

길이는 prelude `size`/`$size`(accumulator)로 계산한다.
반복 목록은 `repeatSeq(0, S) = nil`,
`repeatSeq(s N, S) = S repeatSeq(N, S)`의 직접 재귀 equation으로 구성한다.
typed list는 별도 연산을 선언하지 않고 prelude 연산을 그대로 사용한다.

record 조회/갱신은 field를 매칭하고 prefix에 동일 field가 없다는 조건으로
첫 항목을 선택한다. 없는 field의 조회는 nil, 갱신은 끝에 추가한다.

record 타입의 sequence 필드 F에 `hint(maude_array)`를 붙이면
(`{.., F t* hint(maude_array)}`) F는 목록이 아니라 `sized-array(크기, A)`로
저장한다. A는 prelude `ARRAY{Nat, Zero}`이고, view `Zero`가 기본값을 `# 0`으로
정하므로 0인 칸은 저장하지 않는다(prelude `insert`가 0을 지우고, `_[_]`가 없는
칸에 0을 돌려준다). 크기를 따로 두므로 길이 검사가 칸 수에 비례하지 않는다.
연산은 `SPECTEC-ARRAY`에 있다.

| source | Maude |
|---|---|
| `\|e.F\|` | `array-size(e . 'F)` |
| `e.F[i]` | `array-read(e . 'F, i, 1)` |
| `e.F[i : n]` | `array-read(e . 'F, i, n)` |
| `e[.F[i : n] = s]` | `e[. 'F = array-write(e . 'F, i, n, s)]` |
| `e[.F = s]` | `e[. 'F = array-of(s)]` |
| `{.., F 0^n}` | `sized-array(n, empty)` |
| `{.., F s 0^n}` | `array-grow(⟦s⟧, n)` |
| `{.., F s}` | `array-of(s)` |

`array-read`, `array-write`는 목록 slice/splice처럼 `i + n <= 크기`에서만 정의된다.
`array-of`는 목록을 배열로 바꾼다. 다른 배열 필드의 값은 변환 없이 그대로 쓴다.
필드 pattern(`-- if e = {.., F b*}`)은 배열 값을 그대로 묶고, 번역 전에
(`def.ml:array_script`) 그 뒤의 전제와 결과에서 `b*`를 `e.F`로 바꿔 쓴다.
원문에서 `b* = e.F`이므로 의미가 같고, `|b*|`와 `b* 0^n`이 위 표의 배열 번역을
받는다(Wasm `$growmem`).

위 표 밖의 사용(필드 값 자체를 목록으로 읽기, 원소 하나 갱신, `++` 확장, 필드를
가진 record의 `CompE`)은 `Unsupported`로 거부한다. 이 record 타입에는
`recordConcat` equation을 생성하지 않는다.

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

WAST host memory(spectest `memory`)는 `meminst`의 `BYTES`가 `maude_array`
필드이므로 `sized-array(크기, empty)`로 만든다(`wast_host_encode.ml`). 모듈의 메모리와
data instance는 번역된 `allocmem`/`allocdata`가 만든다.

[language]: https://github.com/Wasm-DSL/spectec/blob/acc6e834ff403c82554d081237f327346190ad96/spectec/doc/Language.md
[type-premises]: https://github.com/Wasm-DSL/spectec/blob/acc6e834ff403c82554d081237f327346190ad96/spectec/doc/Language.md#premises
[formal]: https://github.com/Wasm-DSL/spectec/blob/acc6e834ff403c82554d081237f327346190ad96/spectec/doc/semantics/il/README.md

## Source hints와 handwritten 구현

대상은 [고정 Wasm 원문](../spectec/REVISION)과 그 원문에 붙은 hint다.
hint는 직접 번역하기 어려운 경계를 명시하며, 원문에 없는 계산을 추가하는 허가가 아니다.

### 번역 인터페이스

| Hint | 역할과 적용 조건 |
| --- | --- |
| `maude_sort` | source 타입에 별도 Maude sort와 목록 표현을 부여한다. 목록으로 사용하는 sort들은 하나의 subsort chain이어야 한다. 없는 경우 일반 `SpectecTerminals` 표현을 사용한다. |
| `maude_subsort "T"` | 표시된 source 타입 사이의 subsort 관계. 잘못된 대상·cycle을 거부한다. |
| `maude_proper "V P"` | 선언된 constructor 집합에서 값 V를 제외한 proper sort P를 만든다. instruction 이름을 하드코딩하지 않는다. |
| `maude_array` (record 필드) | 단형 record 타입의 이 sequence 필드를 크기 + prelude `ARRAY`(기본값 0)로 저장한다. 필드 접근은 길이·원소·구간 읽기와 구간·전체 쓰기, 생성은 `0^n`·`s 0^n`·목록으로 제한한다. 다른 사용은 거부한다. 원소의 0은 저장하지 않으므로 원소 타입에 수 0이 있어야 한다. |
| `k_heatcool` | 실행 premise가 있는 rule을 heating/cooling으로 번역한다. premise가 같은 relation의 실행 premise 하나뿐인 context rule은 K embedding(K book §5.4.6)으로 `kstate(R, K)`에 context를 열어 두고, 그 밖의 rule은 split/plug(K book §5.4.5)로 연결한다. `~>` relation의 split과 focus 식별은 equation, `~>*` relation의 split은 rule이다. 적용 조건과 가정은 아래 [적용 범위](#k_heatcool-적용-범위)에 있다. |
| `maude_kind` | 함수의 결과를 partial 화살표 `~>`로 선언한다. 이 hint가 없는 일반 함수는 `->`로 선언한다. |
| `maude_rule` | rewrite premise가 필요한 함수를 request/rule로 번역한다. source 결과와 가능한 분기를 유지한다. |
| `inverse $g` | 빠진 인자를 선언된 역함수 g로 구하고 pattern과 forward 결과를 재확인한다. 인자 순서·signature를 검사한다. |
| `builtin` | 함수 선언을 생성하고 `translator/backend/builtins.maude`의 handwritten 구현에 연결한다. |
| `maude_compute` | relation을 하나의 plain `~~` 또는 `:` 뒤의 출력을 계산하는 partial 연산으로 번역한다. |
| `maude_check` | relation을 모든 component를 받는 partial Bool 검사로 번역한다. 성립하면 `true`, 아니면 결과가 없다. |
| `maude_subsume` (rule) | `maude_compute` relation의 이 rule은 검사 형태다. rule 이름으로 된 별도 Bool 연산(`Ref_ok/sub` → `Ref-ok-sub`)이 되고, 출력까지 알려진 호출은 이 연산을 부른다. 출력을 모르는 호출만 계산 연산을 부른다. |
| `maude_trans "C" ...` (rule) | `maude_check` relation의 추이 rule `R(.., h1, h2) :- R(.., h1, x), R(.., x, h2)`이다. 중간 x는 나열한 nullary constructor 중에서 고르고, 첫 전제는 이 rule을 뺀 `-step` 연산을 쓴다. |
| `maude_assume "R" ...` (rule/def) | 나열한 relation의 전제를 번역하지 않는다. 입력이 그 전제를 이미 만족한다는 가정이며, 아래 적용 범위에 근거를 기록한다. 나열한 relation이 전제에 없으면 거부한다. |

`show`, `macro`, `desc`, `name`, `prose`, `tabular`는 문서 표현용이며 실행 방식을
선택하지 않는다. hint의 형식 검사가 통과했다는 것과 handwritten 구현이 정확하다는
것은 별개의 검사다. source 함수·규칙을 미사용이라는 이유로 삭제하지 않는다.

### Wasm에서의 적용 범위

- `inv_concat_`는 실제 vector 원문의 `(j_1 j_2)*`를 두 원소씩 복원한다.
  `inv_concatn_`는 storage에서 정한 양수 byte 폭으로 복원한다.
  임의 길이 목록의 모든 분할을 찾는 역관계로 확장하지 않는다.
- `$fbits_`의 `inverse` 대상은 `$inv_fbits_`다. 기존의 `$inv_ibits_` 표기는
  로컬 hint 수정으로 바로잡았다. 함수의 계산식은 변경하지 않는다.
- 타입 검사 relation은 실행 rule과 함수의 전제에 나타날 때만 hint를 붙인다.
  `Expand`, `Ref_ok`는 `maude_compute`, `Val_ok`, `Num_ok`, `Vec_ok`,
  `Reftype_sub`, `Heaptype_sub`, `Deftype_sub`는 `maude_check`다.
  hint가 없는 validation relation(`Module_ok`, `Externaddr_ok` 등)은 번역하지 않고,
  그것을 전제로 쓰는 정의는 지원하지 않는다.
- `Ref_ok/sub`: `maude_subsume`, `maude_assume "Reftype_ok"`.
  나머지 rule은 ref 생성자마다 하나씩 실제 타입을 계산한다(partial).
  검사 `Ref-ok-sub(s, ref, rt)`는 그 타입이 `rt`의 subtype인지 본다.
  `Reftype_sub`가 반사적이고 추이적이므로 `Ref_ok/sub`를 여러 번 중첩한 유도와 같다.
  `Reftype_ok {} |- rt`는 `rt`가 검증된 모듈의 `$inst_reftype` 결과이거나
  store instance의 타입이라 닫혀 있고 올바르다는 가정이다(증명하지 않음).
  닫히지 않은 `_IDX` 타입이 들어오면 원문보다 더 받아들일 수 있다.
- `Heaptype_sub/trans`: `maude_trans "ANY" "EQ" "I31" "STRUCT" "ARRAY" "FUNC" "EXN" "EXTERN"`,
  `maude_assume "Heaptype_ok"`. 후보는 모두 `Heaptype_ok/abs`로 OK이므로
  `Heaptype_ok` 생략은 근사가 아니다. bottom 타입(`NONE`, `NOFUNC`, `NOEXN`,
  `NOEXTERN`, `BOT`)을 후보에 넣으면 `NOFUNC <: ANY` 같은 거짓 질의가
  `NONE`/`NOFUNC` 사이를 순환한다. bottom을 거치는 사슬은 none/bot rule이 직접 다룬다.
  deftype 중간값은 `Deftype_sub/super`의 재귀가 다룬다. 이 완전성은 C = {}와
  닫힌 타입에 대한 귀납 논증(semantic review, 미증명)에 근거한다.
  추상 heap type 169쌍 전부를 원문 정의로 계산한 값과 비교해 일치와 종료를 확인했다.
- 실행 중 질의는 C = {}이므로 `_IDX`, `REC` rule은 번역되지만 적용되지 않는다.
- `meminst`, `datainst`의 `BYTES` 필드: `maude_array`. 원문은 메모리(1 page = 65,536칸)와
  data segment 바이트를 목록 `byte*`로 둔다. 목록에서는 범위 검사 `|$mem(z,x).BYTES|`가
  매번 칸 수만큼 세고, 메모리 생성이 칸마다 원소를 만든다(Maude profile에서 확인).
  원문의 사용은 길이, 원소·구간 읽기, 구간 쓰기(`$with_mem`), 전체 쓰기(`$with_data`),
  `0^n` 생성(`allocmem`), 목록 생성(`allocdata`), 필드 pattern 후 `b* 0^n`(`growmem`)이며
  모두 위 표의 형태다. byte의 0은 `%_byte(0)` 형태로 기본값과 대응한다.

### 숫자 builtin과 profile

Wasm f32/f64·bits·bytes·rounding은 원문 `hint(builtin)` 구현의 책임이다.
IL Real 연산의 번역 지원과 Wasm 부동소수점 builtin 지원은 구분한다.
현재 Wasm 입력에 없는 IL Real 연산은 지원하지 않는다. 이것이 Wasm f32/f64
builtin 지원을 제거한다는 뜻은 아니다.
숫자 builtin은 해당 revision의 Wasm numeric 정의와 비교한다.

현재 profile은 `ND=false`, relaxed 선택 0인 Wasm DET이다. 산술 NaN 생성과
부호/payload를 보존하는 negate·abs·copysign·reinterpret를 구분한다.
memory/table grow의 자원 실패 선택은 남는다. DET의 결과를 full profile의 모든
NaN·relaxed 선택에 대한 결과로 일반화하지 않는다.

`otherwise`는 source의 앞선 적용 가능한 규칙이 없다는 조건을 보존해야 한다.
실행 `RelD`의 `ElsePr`은 먼저 선행 입력 패턴의 변수를 현재 입력에 정렬하고,
이미 알려진 순수 조건의 complement를 직접 출력한다. relation parameter는
고정하며, 반복 sequence 변수의 여러 matching 가능성을 임의로 선택하지 않는다.
`Prem.translate_rulepr`가 Bool 조건으로 번역한 relation 호출은 `P =/= true`로,
이미 알려진 결과와의 equation 조건은 `left =/= right`로 직접 부정한다.
현재 caller에서 보장하지 못하는 선행 타입 가드나 새 변수 binding, 입력 패턴의
다른 matching 가능성이 남으면 기존 enabled helper를 사용한다. rewrite 조건은
equational enabled helper로 번역할 수 없으며 기존 진단을 유지한다.

입력의 겹침은 source `CaseE`·`TupE`·`ListE`·`CatE`·`IterE`와 선언된 타입의
constructor를 재귀적으로 비교한다. 원소 타입에 없는 constructor를 필수로
포함하는 sequence는 해당 입력과 겹치지 않는다. 닫힌 constructor 집합을
확인하지 못하는 type parameter·재귀 alias는 보수적으로 검사 대상에 남긴다.
규칙·명령 이름으로 분기하지 않는다.

선행 `MatchCond`와 현재 fallback의 순수 binding이 같은 계산 결과를 같은
구조로 분해하면 출력 변수도 정렬하여 재사용한다. associative spine에 sequence
변수가 여러 개 있어 분해가 유일하지 않으면 이 재사용을 하지 않는다. 실행
premise 뒤에서 얻는 값은 앞선 otherwise 검사로 가져오지 않는다. 앞선
otherwise의 helper 실패 조건도 현재 binding으로 직접 검사할 수 있는 경우,
그 caller 영역에서 이미 구한 동일한 direct 실패 조건으로 대체한다.

현재 Wasm source의 실행 `ElsePr` 35개는 입력값으로 직접 검사하는 31개,
fallback binding을 재사용하는 2개(`array.copy-gt`, `array.init_data-num`),
helper를 사용하는 2개(`throw_ref-handler-next`, `array.init_data-zero`)로
번역한다. 마지막 두 source 규칙이 참조하는 helper 함수는 catch 분기 4개와
array 범위 검사 1개로 총 5개다. 이는 source rule 하나를 실행 rule 하나로
유지하는 방법의 결과이며, 모든 규칙의 분할까지 고려한 helper 불가피성 주장은 아니다.
helper의 `true` equation은 선행 규칙의 입력 패턴을 왼쪽에 직접 사용하고,
그 규칙의 나머지 조건을 검사한다. 일반 입력을 받는 `false [owise]` equation은
입력 패턴이나 조건이 맞지 않은 경우를 처리한다.

값 equality는 `==`와 `=/=`로 반전한다. numeric 비교의 반전과 Bool De Morgan은
total한 비교에만 적용한다. 부분 계산이 남을 수 있는 비교·논리식은 전체
`P =/= true`로 표현하여, 미평가 조건에도 `false [owise]`를 반환하던 helper의
적용 실패를 보존한다. helper의 자동 타입 검사는 모든 caller의 정렬된 입력에서
같은 검사가 보장될 때만 제거하고, caller의 실행 rule에서 먼저 검사한다.
context의 내부 상태는 source 상태와 구분한다. 검색 결과 일치는 임의 LTL 속성의
보존 증명이 아니며, 현재 경계는 [검증과 모델체킹의 경계](#검증과-모델체킹의-경계)에 기록한다.

### k_heatcool 적용 범위

hint는 인자 없이 사용한다(이전 이름: `rl_embedding`, `k_embedding`, `maude_context`).
번역기는 hint가 붙은 rule을 AST 구조로 두 가지로 나눈다. relation·constructor의 Wasm 이름으로 나누지 않는다.

- **context rule**: premise가 같은 relation의 실행 premise 하나뿐인 rule(`R: C[x] ~> C'[x']  -- R: x ~> x'`).
  Wasm 3.0에서는 `Step/ctxt-label`, `Step/ctxt-handler`, `Step/ctxt-frame`이다.
  K embedding(K book §5.4.6)이다. heating과 cooling이 모두 equation이고, context는 안쪽이
  여러 step을 도는 동안 `kstate(R, K)`의 `K`에 열린 채로 남는다.
- **split rule**: 그 밖의 hinted rule. Wasm 3.0에서는 `Step/pure`, `Step/read`, `Step/ctxt-instrs`,
  `Steps/trans`, `Eval_expr`이다. 실행 premise에서 요청과 hole로 나누고(split), 결과를 결론으로
  되돌린다(plug, equation).

split을 equation으로 낼지 rule로 낼지는 relation의 화살표로 정한다.

- `~>` relation(`Step`): split과 focus 식별(`identifyFocus`)이 equation이다. configuration을 나누기만
  하고 실행하지 않으므로 상태를 만들지 않는다. 한 step은 안쪽 relation의 rule 하나다.
- `~>*` relation(`Steps`, `Eval_expr`): split이 rule이다. `Steps/refl`과 `Steps/trans`가 같은 요청에
  모두 적용되는 실제 선택이기 때문이다. 이 relation들은 초기화의 rewrite 조건 안에서만 쓰인다.

실제 source와 생성 결과는 아래 [8개 rule의 변환 예시](#k_heatcool-8개-rule의-변환-예시)에 있다.

split rule은 실행 relation의 RuleD에 적용하며 직접적인 실행 RulePr가 하나 이상 필요하다.
실행 premise마다 이전 binding 중 결과 패턴·남은 조건·결론에 필요한 변수만 hole에 저장한다.
일반 조건과 출력 패턴 검사는 해당 실행의 앞뒤 순서를 유지한다.
sequence-result relation으로 연결하는 단일 premise에서는 대상 입력 패턴으로 식별 helper를 생성한다.
현재 source rule 이름으로 `identifyPure`와 `identifyRead`가 생성된다.
hinted rule의 ElsePr·IterPr·NegPr와 rewrite-backed expression은 현재 Unsupported다.
요청 sort와 반환 sort는 구분하고, hole 인자에는 `[frozen (2)]`를 부여해 rule rewriting을 막는다.

**equation split의 조건과 근거.** equation은 한 번 고르면 되돌아가지 않으므로 다음을 지킨다.

- 식별 helper는 대상 rule의 입력 패턴과, 입력 변수만 쓰는 equational premise(예: trap-instrs의
  `val* =/= eps \/ instr* =/= eps`)를 함께 검사한다. 어떤 rule도 실행할 수 없는 입력(끝에 남은
  `TRAP` 하나 등)은 split하지 않고 `Step(c)`로 남는다. 한 focus에 pure·read·Step rule이 함께 맞지
  않아야 한다. Wasm 3.0에서 세 쪽 rule의 trigger 명령이 겹치지 않음을 생성 패턴으로 확인했다(증명 아님).
- `identifyFocus`와 split이 equation이면 갈래가 여러 개일 때 하나만 고른다(equation은 confluent하지
  않다). Wasm 3.0에서 갈래가 여러 개인 것은 `val*`·`instr*`를 흡수하는 trap-instrs와 throw_ref-instrs뿐이다.
  예: `c1 c2 TRAP NOP`의 source 다음 상태는 5개(`TRAP`, `c1 TRAP`, `TRAP NOP`, …)지만 생성 코드는
  하나만 만든다. 또 `c1 (REF.EXN_ADDR a) THROW_REF NOP`에는 ctxt-instrs split과 read split이 함께
  맞는다. 이 갈래들은 store를 바꾸지 않고 같은 `TRAP`·`REF.EXN_ADDR a THROW_REF`로 모이므로,
  **중간 상태를 줄이는 축소**이지 step 단위 대응이 아니다. 관측 명제가 명령 목록 모양이나 X(next)를
  보지 않으면 결과가 같다(stuttering). 근거: `WasmSuiteTest/spec2maude-results/20261029-focus-eq`.
- 모델체킹 상태의 configuration은 split된 요청을 담을 수 있다. configuration을 보는 명제는
  `cool-all(unheat(R), K)`로 읽어야 한다(현재 명제 `returned`는 `finished(...)`만 본다).
- 실행 rule이 상태에 직접 적용되므로, 결과가 계산식인 실행 rule은 결과를 결과 sort 변수에 `:=`로
  묶는다(`reld.ml:execution_statement`). 범위 밖 store처럼 부분 함수가 정의되지 않으면 그 rule은
  적용되지 않는다. source에서도 결과가 정의되지 않는 rule은 step이 아니다.

context rule의 적용 조건은 다음과 같다. 맞지 않으면 진단과 함께 Unsupported다.

- context가 안쪽 step 동안 바뀌지 않는다: 결론 출력에 premise 입력을 다시 넣으면 결론 입력이 된다
  (`C'[x]`가 `C[x]`). frame처럼 상태 일부를 안쪽과 바꾸는 것은 허용한다.
- 결론 입력의 sequence가 context 원소 하나 `E`이고, premise는 `E`의 인자인 sequence 변수 `x`를 실행한다.
- 같은 relation에 split rule의 sequence context(`val* instr* instr_1*`)가 정확히 하나 있고,
  그 rule에 `val* =/= eps \/ instr_1* =/= eps` 조건이 있다.
- `E`를 소비하는 rule이 하나 이상 있다(아래 closed body).

생성 결과(`R`의 rule 이름을 `R-r`이라 하면):

```maude
kstate(z ; PREFIX E POSTFIX, K) = kstate(z ; E, hole(PREFIX, POSTFIX) K)
  if _or_(PREFIX =/= nil, POSTFIX =/= nil) /\ closed-R-r(x) = false .     --- instrs heating
kstate(C[x], K) = kstate(x, hole-R-r(..) K)  if closed-R-r(x) = false .   --- heating
kstate(x', hole-R-r(..) K) = kstate(C'[x'], K)  if closed-R-r(x') = true .  --- cooling
kstate(z ; s, hole(PREFIX, POSTFIX) K) = kstate(z ; PREFIX s POSTFIX, K) [owise] .  --- instrs cooling
kstate(c, K) = kstate(Step(c), K)  if plug-first(K) = false [owise] .       --- 요청으로 감싸기
cool-all(c, K)                                                               --- 모든 hole을 다시 붙인 configuration
unheat(r)                                                                    --- split된 요청이 나타내는 configuration
```

closed body는 sequence context의 focus pattern 중 trigger가 `E`의 constructor인 것에서
`x` 자리의 패턴이다. 즉 `E` 자체를 소비하는 rule(label-vals, br-label, return-frame 등)의
body 모양이며, Wasm 이름이 아니라 source rule에서 뽑는다. instrs cooling은 heating 조건이
맞지 않을 때만 적용되므로 `[owise]`다. context equation이 더 적용되지 않고 기다리는 sequence
hole도 없으면, configuration을 relation의 요청으로 감싼다. 그러면 split equation이 focus를 찾고,
relation의 rule 하나가 그 자리에서 한 step을 실행한다.

**가정.** closed body에는 같은 relation의 Step이 단독으로 적용되지 않는다고 가정한다.
이 가정이 깨지면 K embedding은 그 body를 열지 않으므로 안쪽 step 가지를 잃는다.
번역기는 이 가정을 검사하지 않는다. Wasm 3.0에서는 rule.maude의 해당 rule들과 대조해 확인했다
(br/return/return_call_ref에는 context 밖 rule이 없고, trap-instrs와 throw_ref-instrs는 앞뒤에 다른
명령이 있을 때만 적용된다).

**상태 대응.** `cool-all(unheat(R), K)`가 source configuration이다. 실행 상태 안에서 rule이 한 번
적용되는 것이 source Step 한 번이고, heating·cooling·split·focus는 equation이라 상태를 만들지 않는다
(K book Theorem 13, step-for-step correspondence). fib(10)에서 계산 rule 적용 수(2,036)가 이전
rewrite-condition driver와 같고, growbuf(n=128)의 도달 상태 수(3,008)·최종 상태·LTL 반례가 같음을
확인했다(`WasmSuiteTest/spec2maude-results/20261029-step2-heateq`). 유한 입력에 대한 확인이며 증명이 아니다.

`Steps`와 `Eval_expr`는 driver 없이 `Step`을 직접 부른다. `Step`에는 context rule로
들어가는 rule이 없으므로, 이 경로는 LABEL_/HANDLER_/FRAME_가 없는 식에만 맞다. 이들이 평가하는
상수식에는 그런 명령이 없다.

## k_heatcool: 8개 rule의 변환 예시

아래는 현재 source와 생성된 Maude 문장이다. 보조 선언과 식별 규칙 전체는 생략했다.

### 번역 계약과 구조

`RuleD`의 실제 실행 `RulePr`를 식별하고, 기존 `Prem` 번역 결과를 사용한다. 실행 조건을 만나면 요청과 hole을 생성하고 남은 조건을 재귀적으로 번역한다. hole에는 이미 binding된 변수 중 내부 결과 패턴·나머지 조건·최종 결론에서 필요한 것만 저장한다. 모든 조건을 처리하면 원래 결론으로 plug한다. 일반 조건을 다음 실행 premise 앞뒤로 넘기지 않는다.

LABEL, FRAME 등의 이름으로 분기하지 않으며, 식별 helper와 hole 이름은 source rule에서 생성한다. 별도 evaluator나 범용 premise 프레임워크를 추가하지 않는다.

실행 요청과 반환 결과는 sort로 구분한다. plug는 반환 결과 패턴에만 적용된다. `Eval_expr`는 `VAL* : ValList`가 이 역할을 하므로 별도 typecheck를 삽입하지 않는다. `_~>_`의 hole 인자는 `[frozen (2)]`로 rule rewriting을 막는다. equation 정규화까지 금지한다는 뜻은 아니다.

실행할 rule이 없는 요청은 그 모양으로 멈춘다. driver는 `kstate(Step(z ; vals), none)`를 완료로 본다. raw 요청의 search/LTL을 source 상태의 search/LTL과 동일시하지 않는다. 유한 입력과 제한된 탐색 깊이의 결과 검사만으로 전체 의미 보존을 주장하지 않는다.

### 1. Step/pure (split, equation)

```spectec
rule Step/pure:
  z; instr*  ~>  z; instr'*
  -- Step_pure: instr* ~> instr'*
  hint(k_heatcool)
```

```maude
ceq Step(Z ; INSTR*) = Step-pure(INSTR*) ~> hole-Step-pure(Z)
    if identifyPure(INSTR*) .

eq INSTR'* ~> hole-Step-pure(Z) = Z ; INSTR'* .
eq unheat(Step-pure(INSTR*) ~> hole-Step-pure(Z)) = Z ; INSTR* .

ceq identifyPure(VAL* (TRAP INSTR*)) = true
    if _or_(VAL* =/= nil, INSTR* =/= nil) .
```

`identifyPure(INSTR*)`로 입력 후보를 확인한다. 내부 instruction 결과에 원래 상태 Z를 붙인다.

### 2. Step/read (split, equation)

```spectec
rule Step/read:
  z; instr*  ~>  z; instr'*
  -- Step_read: z; instr* ~> instr'*
  hint(k_heatcool)
```

```maude
ceq Step(Z ; INSTR*) = Step-read(Z ; INSTR*) ~> hole-Step-read(Z)
    if identifyRead(Z ; INSTR*) .

eq INSTR'* ~> hole-Step-read(Z) = Z ; INSTR'* .
eq unheat(Step-read(Z ; INSTR*) ~> hole-Step-read(Z)) = Z ; INSTR* .
```

`identifyRead(Z ; INSTR*)`로 입력 후보를 확인한다. 읽기 실행은 instruction 목록을 반환하므로 원래 상태 Z를 붙인다.

### 3. Step/ctxt-instrs (split, equation)

```spectec
rule Step/ctxt-instrs:
  z; val* instr* instr_1*  ~>  z'; val* instr'* instr_1*
  -- Step: z; instr* ~> z'; instr'*
  -- if val* =/= eps \/ instr_1* =/= eps
  hint(k_heatcool)
```

```maude
ceq Step(Z ; (STACK (OP REST))) = Step(Z ; FOCUS) ~> hole(PREFIX, POSTFIX)
    if (STACK (OP REST)) =/= OP
      /\ { PREFIX | (Z ; FOCUS) | POSTFIX } := identifyFocus(Z, STACK, OP, REST)
      /\ FOCUS =/= (PREFIX (FOCUS POSTFIX)) .

eq (Z' ; INSTR'*) ~> hole(PREFIX, POSTFIX) = Z' ; (PREFIX (INSTR'* POSTFIX)) .
eq unheat(R-3 ~> hole(PREFIX, POSTFIX)) = unheat(R-3) ~> hole(PREFIX, POSTFIX) .
```

`identifyFocus` 식도 equation이다(`eq identifyFocus(...) = { ... }`). source의 nonempty 조건은 guard로 남는다.
매 step 자르는 자리가 바뀌므로(앞 명령의 결과가 다음 명령의 operand) 열어 두지 않는다.
context rule(ctxt-label/handler/frame)에는 focus pattern을 만들지 않는다.

### 4. Step/ctxt-label (context rule)

```spectec
rule Step/ctxt-label:
  z; (LABEL_ n `{instr_0*} instr*)  ~>  z'; (LABEL_ n `{instr_0*} instr'*)
  -- Step: z; instr* ~> z'; instr'*
  hint(k_heatcool)
```

```maude
ceq kstate(Z ; (PREFIX ((LABEL- N-3 { INSTR_0* } INSTR*) POSTFIX)), K-4) = kstate(Z ; (LABEL- N-3 { INSTR_0* } INSTR*), hole(PREFIX, POSTFIX) K-4)
    if _or_(PREFIX =/= nil, POSTFIX =/= nil)
      /\ closed-Step-ctxt-label(INSTR*) = false .

ceq kstate(Z ; (LABEL- N-3 { INSTR_0* } INSTR*), K-4) = kstate(Z ; INSTR*, hole-Step-ctxt-label(INSTR_0*, N-3) K-4)
    if closed-Step-ctxt-label(INSTR*) = false .

ceq kstate(Z' ; INSTR'*, hole-Step-ctxt-label(INSTR_0*, N-3) K-4) = kstate(Z' ; (LABEL- N-3 { INSTR_0* } INSTR'*), K-4)
    if closed-Step-ctxt-label(INSTR'*) = true .

eq cool-all(Z' ; INSTR'*, hole-Step-ctxt-label(INSTR_0*, N-3) K-4) = cool-all(Z' ; (LABEL- N-3 { INSTR_0* } INSTR'*), K-4) .

eq closed-Step-ctxt-label(VAL*) = true .
eq closed-Step-ctxt-label(((VAL'* VAL*) BR(L)) INSTR*) = true .
eq closed-Step-ctxt-label((VAL* BR(L)) INSTR*) = true .
eq closed-Step-ctxt-label((VAL* RETURN) INSTR*) = true .
eq closed-Step-ctxt-label(TRAP) = true .
eq closed-Step-ctxt-label((VAL* RETURN-CALL-REF(YY-2)) INSTR*) = true .
eq closed-Step-ctxt-label(REF.EXN-ADDR(A) THROW-REF) = true .
eq closed-Step-ctxt-label(INSTR-3) = false [owise] .
```

closed body는 label-vals, br-label-zero, br-label-succ, return-label, trap-label,
return_call_ref-label, throw_ref-label의 body다.

### 5. Step/ctxt-handler (context rule)

```spectec
rule Step/ctxt-handler:
  z; (HANDLER_ n `{catch*} instr*) ~> z'; (HANDLER_ n `{catch*} instr'*)
  -- Step: z; instr* ~> z'; instr'*
  hint(k_heatcool)
```

ctxt-label과 같은 모양이다(hole `hole-Step-ctxt-handler(CATCH*, N-3)`). closed body는 br-handler,
return-handler, handler-vals, trap-handler, return_call_ref-handler, throw_ref-handler-*의 body다.

### 6. Step/ctxt-frame (context rule)

```spectec
rule Step/ctxt-frame:
  s; f; (FRAME_ n `{f'} instr*)  ~>  s'; f; (FRAME_ n `{f''} instr'*)
  -- Step: s; f'; instr* ~> s'; f''; instr'*
  hint(k_heatcool)
```

```maude
ceq kstate((S-2 ; F) ; (FRAME- N-3 { F' } INSTR*), K-4) = kstate((S-2 ; F') ; INSTR*, hole-Step-ctxt-frame(N-3, F) K-4)
    if closed-Step-ctxt-frame(INSTR*) = false .

ceq kstate((S' ; F'') ; INSTR'*, hole-Step-ctxt-frame(N-3, F) K-4) = kstate((S' ; F) ; (FRAME- N-3 { F'' } INSTR'*), K-4)
    if closed-Step-ctxt-frame(INSTR'*) = true .
```

heating에서 안쪽 frame F'로 바꾸고 바깥 frame F를 hole에 둔다. cooling에서 store S'와 안쪽
frame F''는 실행 결과를 쓴다. instrs heating과 closed body(frame-vals, return-frame, trap-frame,
return_call_ref-frame-null/addr, throw_ref-frame)는 ctxt-label과 같은 방식으로 생성된다.

### 공통 선언, 요청으로 감싸기, instrs cooling

```maude
op none : -> Holes [ctor] .
op __ : Holes Holes -> Holes [ctor assoc id: none] .
op kstate : Step-Request Holes -> KState [ctor frozen (2)] .
op cool-all : SpectecTerminal Holes -> SpectecTerminal .
op unheat : Step-Request ~> Step-Request .

eq cool-all(C-5, none) = C-5 .
eq cool-all(Z-2 ; INSTR-3, hole(PREFIX, POSTFIX) K-4) = cool-all(Z-2 ; (PREFIX (INSTR-3 POSTFIX)), K-4) .
eq unheat(Step(C-5)) = C-5 .
eq plug-first(hole(PREFIX, POSTFIX) K-4) = true .
eq plug-first(K-4) = false [owise] .
eq kstate(Z-2 ; INSTR-3, hole(PREFIX, POSTFIX) K-4) = kstate(Z-2 ; (PREFIX (INSTR-3 POSTFIX)), K-4) [owise] .
ceq kstate(C-5, K-4) = kstate(Step(C-5), K-4)
    if plug-first(K-4) = false [owise] .
```

`kstate`의 첫 인자는 frozen이 아니다. 실행 driver(`wasm2maude/*-runtime.maude`, harness)는 상태를
`exec(kstate(C, none))`로 시작하고, `Step` rule이 그 안에서 직접 적용된다(rewrite 조건 없음).
완료는 `kstate(Step(z ; vals), none)`이다. wast 실행기는 참조 인터프리터처럼 결정적 실행 하나를
따라가야 하므로, 각 step을 rewrite 조건 `KS => KS2 /\ KS2 =/= KS`의 가장 가까운 해로 진행한다
(rule 선언 순서; 예: memory.grow-succeed가 memory.grow-fail보다 먼저). exhaustion 검사는 step마다
`cool-all(unheat(R), K)`의 frame 깊이를 본다.

### 7. Steps/trans (split, rule)

```spectec
rule Steps/trans:
  z; instr*  ~>*  z''; instr''*
  -- Step: z; instr*  ~>  z'; instr'*
  -- Steps: z'; instr'*  ~>*  z''; instr''*
  hint(k_heatcool)
```

```maude
rl [split-Steps-trans] : Steps(Z ; INSTR*) => Step(Z ; INSTR*) ~> hole-Steps-trans-Step .

eq (Z' ; INSTR'*) ~> hole-Steps-trans-Step = Steps(Z' ; INSTR'*) ~> hole-Steps-trans-Steps .

eq (Z'' ; INSTR''*) ~> hole-Steps-trans-Steps = Z'' ; INSTR''* .

rl Steps(Z ; INSTR*) => Z ; INSTR* .
```

첫 Step의 결과를 다음 Steps에 전달한다. Steps/refl은 0회 실행을 보존하는 rule로 유지한다. 두 번째 hole은 원래 결론을 반환한다.

### 8. Eval_expr (split, rule)

```spectec
rule Eval_expr:
  z; instr*  ~>*  z'; val*
  -- Steps: z; instr*  ~>*  z'; val*
  hint(k_heatcool)
```

```maude
rl [split-Eval-expr] : Eval-expr(Z, INSTR*) => Steps(Z ; INSTR*) ~> hole-Eval-expr .

eq (Z' ; VAL*) ~> hole-Eval-expr = tuple(Z' seq(VAL*)) .
```

VAL*의 sort는 ValList다. NOP/TRAP 등의 비-value 목록과 실행 중 요청은 이 plug 패턴에 매치하지 않는다. tuple 모양도 원래 출력과 같다.

### 지원 범위와 검증

직접적인 실행 RulePr, 실행 전후의 일반 조건과 binding, 여러 실행 premise 연결을 지원한다. hinted rule 안의 ElsePr·IterPr·NegPr 및 rewrite-backed expression은 현재 명시적인 Unsupported다. 지원하지 않는 구조를 평범한 rule로 조용히 되돌리지 않는다. 기존 목록 context의 지원 범위는 유지한다.

`4.4-execution.modules.spectec`의 `$evalexprs`, `$evalglobals`는 함수 정의 절이므로 위 relation rule 8개에 포함하지 않았다. 이들은 기존 번역을 유지하며, 변경된 Eval_expr를 호출한다.

번역과 Maude load 확인:

```sh
dune build
dune exec bin/spec2maude.exe --
test/spectec_to_maude.sh
```

위 명령은 source 번역, 생성 파일 비교와 Maude load를 확인한다. 실행 결과 검사나 전체 공식 suite, 성능 비교, 일반 search/LTL 의미 보존 증명을 대신하지 않는다. 실행 및 suite 검사 방법은 [ARTIFACT.md](ARTIFACT.md)에 둔다.
