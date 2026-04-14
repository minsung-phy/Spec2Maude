# Spec2Maude 변환 논리 (Translation Logic)

> 대상 독자: 지도 교수님 및 랩실 연구원  
> 문서 버전: 2026-04-14  
> 관련 파일: `translator.ml`, `output.maude`, `wasm-3.0/*.spectec`

---

## 1. 개요

Spec2Maude 번역기는 WebAssembly 3.0의 공식 명세인 SpecTec 소스 파일을 파싱 및 Elaborate하여 얻은 **Intermediate Language (IL) AST**를 입력으로 받아, Maude의 대수적 명세인 **SPECTEC-CORE** 모듈을 자동 생성합니다.

번역은 크게 두 단계로 나뉩니다.

```
*.spectec  →  [SpecTec Frontend]  →  IL AST  →  [translator.ml]  →  output.maude
```

IL AST의 핵심 노드 유형과 그에 대응하는 Maude 출력의 매핑은 아래 표와 같습니다.

| IL AST 노드 (`def'`) | SpecTec 의미 | Maude 출력 |
|---|---|---|
| `TypD` | 타입 정의 (`syntax`) | `sort` + `op` (생성자) + 멤버십 판정 `eq`|
| `DecD` | 보조 함수 정의 (`def`) | `op $f : ... -> WasmTerminal` + `[c]eq` |
| `RelD` (일반) | 관계 정의 (`relation`) | `op R : ... -> Bool` + `ceq R(lhs) = true` |
| `RelD` (Step 계열) | 실행 의미론 규칙 | `[c]eq step(< Z \| LHS IS >) = < Z' \| RHS IS >` |
| `RecD` | 상호 재귀 정의 | 포함 정의들을 순서대로 재귀 처리 |

---

## 2. Pre-scan 단계 (단일 패스 AST 순회)

번역 본체에 앞서, 전체 AST를 단일 패스로 순회하는 **Pre-scan** 단계가 실행됩니다. 이 단계는 두 종류의 정보를 수집합니다.

### 2-1. Bare Atom Token 수집

SpecTec의 mixfix 연산자(예: `i32`, `add`, `local.get`)에서 인자를 받지 않는 낱개 원자 토큰을 수집하여, 다음과 같이 Maude nullary 생성자로 선언합니다.

```maude
ops CTORI32A0 CTORADDA0 CTORLOCALGETA0 ... : -> WasmTerminal [ctor] .
```

이를 통해 번역기 소스 코드에 특정 명령어 이름을 단 하나도 하드코딩하지 않고, AST를 통해 자동으로 필요한 토큰 집합을 결정합니다.

### 2-2. 함수 호출 시그니처 수집

`DecD`에서 정의된 보조 함수의 이름과 인자 수를 수집하여, 번역 본체에서 `CallE` 노드를 만났을 때 정확한 ariy를 가진 Maude `op` 선언을 생성할 수 있도록 합니다.

---

## 3. 타입 정의 번역: `TypD → Sort + Op`

SpecTec의 `syntax` 정의는 세 가지 형태로 분류됩니다.

### 3-1. Alias 타입

```spectec
syntax labelidx = u32
```

→ `subsort U32 < Labelidx .` (존재하면) 또는 Alias op 생성자 발행.

### 3-2. Struct 타입

```spectec
syntax state = { store : store, frame : frame }
```

각 필드는 `item('FIELDNAME, value)` 형태의 레코드 엔트리로 인코딩됩니다. 멤버십 판정 방정식이 함께 생성됩니다.

```maude
ceq T : State = true
  if value('STORE, T) : Store = true
  /\ value('FRAME, T) : Frame = true .
```

### 3-3. Variant 타입

```spectec
syntax instr =
  | UNREACHABLE
  | CONST numtype c
  | ...
```

각 생성자 케이스는 아리티(arity) n에 따라 `CTORNAMEAn` 형태의 Maude 생성자 선언으로 변환됩니다.

```maude
op CTORUNREACHABLEA0 : -> WasmTerminal [ctor] .
op CTORCONSTA2 : WasmTerminal WasmTerminal -> WasmTerminal [ctor] .
```

멤버십 판정 방정식:

```maude
eq CTORUNREACHABLEA0 : Instr = true .
ceq CTORCONSTA2(NT, C) : Instr = true
  if NT : Numtype = true /\ C : Const = true .
```

---

## 4. 보조 함수 번역: `DecD → Op + [C]Eq`

SpecTec의 `def` 절은 패턴 매칭 방정식 집합으로 표현됩니다. 각 clause는 다음 순서로 처리됩니다.

### 4-1. 바인더(Binder) 처리 → 변수 맵 생성

각 rule 내의 `binders: bind list`는 `binder_to_var_map` 함수에 의해  
`{ spectec_id → maude_var_name }` 딕셔너리로 변환됩니다.  
변수 이름에는 충돌 방지를 위해 `{PREFIX}-{BINDER_NAME}` 형식의 고유 접두사가 붙습니다.

```ocaml
let binder_to_var_map prefix eq_idx binders =
  List.mapi (fun i b ->
    let key = id_of_bind b in
    (key.it, Printf.sprintf "%s-%s" prefix (String.uppercase_ascii key.it))
  ) binders
```

### 4-2. 전제(Premise) 스케줄링

clause의 전제 목록(`prem list`)은 `schedule_prems` 함수에 의해 위상정렬됩니다.  
전제는 다음 두 유형으로 분류됩니다.

- **바인딩 전제** (`LetPr`, `IfPr`): 새로운 변수를 도입하는 전제. LHS 패턴에 등장한 변수가 먼저 바인딩된 후 해당 전제가 배치됩니다.
- **불리언 전제** (`RulePr`, `IfPr`): 이미 바인딩된 변수만을 참조하는 불리언 조건.

위상정렬의 목표는 모든 전제가 Maude `if` 조건에서 **왼쪽부터 순서대로** 평가될 때 미바인딩 변수가 없도록 보장하는 것입니다.

### 4-3. 방정식 출력

```
(binders) → var map → schedule prems → generate cond string
                                              ↓
             [c]eq $fname(lhs_terms) = rhs_term [if cond] .
```

예: `$local(F, X) = index(value('LOCALS, F), X)`

```maude
ceq $local(DECD-LOCAL-F, DECD-LOCAL-X) = index(value('LOCALS, DECD-LOCAL-F), DECD-LOCAL-X)
  if DECD-LOCAL-F : Frame /\ DECD-LOCAL-X : Idx .
```

---

## 5. 관계 번역 (일반): `RelD → Op Bool + CeQ`

Step 계열을 제외한 관계(Typing, Validation 등)는 Bool 반환 연산자로 번역됩니다.

```spectec
relation Expand: functype -> functype
```

→

```maude
op Expand : WasmTerminal WasmTerminal -> Bool .
ceq Expand(LHS, RHS) = true if COND .
```

relation의 arity는 conclusion의 `TupE` 자식 수로 결정됩니다.

---

## 6. 실행 의미론 규칙 번역: `RelD (Step 계열) → step 방정식`

### 6-1. Step 계열 탐지

`is_step_exec_rel` 함수가 관계 이름을 검사합니다.

```ocaml
let is_step_exec_rel name =
  name = "Step" || name = "Step-pure" || name = "Step-read"
```

이 세 관계는 `translate_step_reld`로 라우팅됩니다.

### 6-2. 브리지/컨텍스트 규칙 필터링

`has_rule_premise` 함수는 rule의 전제 목록에 `RulePr` 노드가 포함되어 있는지 검사합니다.

```ocaml
let has_rule_premise prems =
  List.exists (fun p -> match p.it with RulePr _ -> true | _ -> false) prems
```

`RulePr`을 포함하는 규칙은:
- **브리지 규칙** (`Step/pure`, `Step/read`): Step-pure나 Step-read를 Step으로 올리는 규칙
- **평가 문맥 규칙** (`Step/ctxt-label`, `Step/ctxt-frame`): 레이블/프레임 내부로 실행을 위임하는 규칙

이들은 `wasm-exec.maude`의 heating/cooling 패턴(`exec-step`, `restore-label` 등)이 처리하므로 자동 번역에서 제외됩니다.

### 6-3. Config 분해: `try_decompose_config`

Step 및 Step-read relation의 결론(conclusion)에서 config 표현식 `z ; instr*`을 분해합니다.

```ocaml
let try_decompose_config (e : exp) : (exp * exp) option =
  match e.it with
  | CaseE (mixop, inner) ->
      let arity = match inner.it with TupE es -> List.length es | _ -> 1 in
      (match canonical_ctor_name_arity mixop arity with
       | Some name when name = "CTORSEMICOLONA2" ->
           (match inner.it with
            | TupE [z_e; instr_e] -> Some (z_e, instr_e)
            | _ -> None)
       | _ -> None)
  | _ -> None
```

SpecTec IL에서 `z ; instr*`는 `CaseE(semicolon_mixop, TupE [z_e, instr_e])`로 표현됩니다. 함수는 이를 탐지하여 State 부분 `z_e`와 명령어 시퀀스 부분 `instr_e`를 분리합니다.

### 6-4. 세 가지 변형에 대한 매핑 규칙

각 관계 변형이 어떻게 결론을 해석하는지, 그리고 어떤 Maude 방정식을 생성하는지를 형식적으로 정의합니다.

#### Step-pure

SpecTec 결론 형식: `instr* ~>_pure instr'*`  
IL 표현: `TupE [lhs_instrs, rhs_instrs]`  
(State가 없으므로 신선한 변수 `Z`를 도입)

생성 규칙:

```
var PREFIX-Z : WasmTerminal .
[c]eq step(< PREFIX-Z | LHS IS >) = < PREFIX-Z | RHS IS > [if COND] .
```

예: `unreachable ~>_pure trap`

```maude
eq step(< STEP-PURE-UNREACHABLE-Z | CTORUNREACHABLEA0 STEP-PURE-UNREACHABLE-IS >)
   = < STEP-PURE-UNREACHABLE-Z | CTORTRAPA0 STEP-PURE-UNREACHABLE-IS > .
```

#### Step-read

SpecTec 결론 형식: `z;instr* ~>_read instr'*`  
IL 표현: `TupE [CaseE(semicolon, TupE[z_e, lhs_e]), rhs_e]`  
(`try_decompose_config`로 z_e와 lhs_e를 분리)

생성 규칙:

```
[c]eq step(< Z | LHS IS >) = < Z | RHS IS > [if COND] .
```

예: `z;local.get x ~>_read val`

```maude
ceq step(< STEP-READ-LOCAL-GET25-Z | CTORLOCALGETA1(STEP-READ-LOCAL-GET25-X) STEP-READ-LOCAL-GET-IS >)
    = < STEP-READ-LOCAL-GET25-Z | STEP-READ-LOCAL-GET25-VAL STEP-READ-LOCAL-GET-IS >
    if (... = STEP-READ-LOCAL-GET25-VAL) = true /\ ... .
```

#### Step

SpecTec 결론 형식: `z;instr* ~> z';instr'*`  
IL 표현: `TupE [CaseE(semicolon, TupE[z_e, lhs_e]), CaseE(semicolon, TupE[zp_e, rhs_e])]`  
(양쪽 모두 `try_decompose_config` 적용)

생성 규칙:

```
[c]eq step(< Z | LHS IS >) = < Z' | RHS IS > [if COND] .
```

---

## 7. 표현식(Expression) 번역: `translate_exp`

IL AST의 `exp'` 노드는 재귀적으로 번역됩니다. 핵심 케이스는 아래와 같습니다.

| IL `exp'` 노드 | 의미 | Maude 출력 예 |
|---|---|---|
| `VarE id` | 변수 참조 | `VM-LOOKUP(id)` (변수 맵 적용) |
| `NumE n` | 정수/실수 리터럴 | `42` |
| `BinE(Add, _, e1, e2)` | 산술 연산 | `(e1 + e2)` |
| `CmpE(Eq, _, e1, e2)` | 비교 연산 | `(e1 == e2)` |
| `CaseE(mixop, e)` | 생성자 적용 | `CTORNAMEA2(arg1, arg2)` |
| `CallE(id, args)` | 함수 호출 | `$fname(arg1, arg2)` |
| `DotE(e, atom)` | 레코드 필드 접근 | `value('FIELD, expr)` |
| `UpdE(e, path, v)` | 레코드 필드 갱신 | `expr [. 'FIELD <- v]` |
| `LenE(e)` | 시퀀스 길이 | `length(expr)` |
| `IdxE(e, i)` | 인덱스 접근 | `index(expr, i)` |
| `IterE(e, (List, _))` | 리스트 이터레이션 | `expr` (WasmTerminals로 전개) |
| `IfE(cond, t, f)` | 조건 표현식 | `if cond then t else f fi` |

`translate_exp`는 `texpr = { text: string; vars: string list }` 레코드를 반환합니다. `vars`는 해당 표현식이 참조하는 자유 변수 목록으로, 전제 스케줄링에 활용됩니다.

---

## 8. 생성된 파일 통계 (output.maude 기준)

| 항목 | 수량 |
|------|------|
| 전체 파일 길이 | 7,066줄 |
| 방정식/규칙 (`eq`/`ceq`/`rl`/`crl`) | 1,368개 |
| `step` 방정식 (Step 계열 자동 생성) | 189개 |
| 연산자 선언 (`op`/`ops`) | 1,009개 |
| Sort/subsort 선언 | 307개 |
