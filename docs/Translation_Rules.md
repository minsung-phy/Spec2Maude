# Spec2Maude Translation Rules

> 작성일: 2026-04-17
> 관련 파일: `translator.ml`, `main.ml`, `dsl/pretype.maude`, `output.maude`

> 로드 warning/advisory의 정량 분석 및 해결 우선순위는 `docs/maude_warning_analysis.md` 참고.

---

## 1. Architecture Overview

### 1.1 Pipeline

```
*.spectec files
      │
      ▼
  SpecTec Frontend  (lib/frontend)
  Parse → Elaborate
      │
      ▼
  Elaborated IL AST  (lib/il/ast.ml)
      │
      ▼
  translator.ml
  (Pre-scan → Translate → Reorder)
      │
      ▼
  output.maude
  (mod SPECTEC-CORE, 7,065 lines)
      │
      ▼
  load dsl/pretype + wasm-exec.maude
      │
      ├─► rewrite [N] : steps(config) .   (equational reduction)
      └─► modelCheck(config, φ) .         (LTL verification)
```

`main.ml`은 모든 파일을 먼저 파싱한 후 **한 번에 Elaborate** 한다. 파일 경계를 넘는 참조(예: `1.2-syntax.types`의 타입이 `4.3-execution.instructions`의 규칙에서 쓰이는 경우)를 해결하기 위해 반드시 필요한 구조다.

---

### 1.2 Two-Phase Translation

**1단계 : 프리 스캔 (Pre-scan)** (`scan_def`, `build_token_ops`, `build_call_ops`)

전체 AST를 한 번 순회하며 다음 정보들을 수집한다.

| 산출물 (Artifact) | 자료 구조 | 목적 (Purpose) |
|---|---|---|
| 단순 토큰 (Bare tokens) | `SSet.t tokens` | mixfix 패턴에 등장하는 원자(atom) 중 `VariantT` 생성자가 아닌 것들 (예: `A0`, `S`, `U`). `[ctor] : -> WasmTerminal` 로 일괄 선언 |
| 생성자 이름 (Constructor names) | `SSet.t ctors` | `VariantT` 케이스의 첫 원자로 선언된 이름. `tokens`와 중복 선언을 막기 위해 차집합 처리 |
| 호출 시그니처 (Call signatures) | `SIPairSet.t calls` | 선언되지 않은 헬퍼 함수들의 (함수명, 인자 수) 쌍. 이후 `build_call_ops`가 자동 `op $f : WasmTerminal^n -> …` 선언 발행 |
| 불리언 문맥 호출 (Bool-context calls) | `SSet.t bool_calls` | `IfPr`/`and`/`or`/`not` 내부에서 호출된 함수 수집. 반환 타입을 `Bool` 로 지정 |
| 선언된 함수 (Declared functions) | `SSet.t dec_funcs` | `DecD` 로 이미 선언된 함수 이름. Auto-declaration 과 중복 방지 |

**2단계 : 변환 (Translation)** (`translate_definition`)

각 AST 노드는 해당하는 핸들러(`translate_typd`, `translate_decd`, `translate_reld`, `translate_step_reld`)로 전달되어 Maude 소스 텍스트를 생성한다.

마지막 재정렬(reordering) 패스에서 선언부(`op`, `ops`, `var`, `vars`, `subsort`, `sort`)와 방정식부(`eq`, `ceq`, `mb`, `cmb`)를 분리하여, **출력 파일의 모든 선언부가 방정식부보다 먼저 위치하도록** 배치한다. 동시에 다음 post-processing 단계를 수행한다.

1. 방정식 본문에서 사용되는 모든 `CTOR<name>A<arity>` 토큰을 스캔해서 누락된 canonical 생성자 `op` 선언을 추가한다.
2. 같은 이름의 `op X : -> WasmType [ctor]` (0-arity) 과 `op X : WasmTerminal … -> WasmType [ctor]` (≥1-arity) 가 공존할 때 0-arity 쪽을 제거 → `multiple distinct parses` 경고 최소화.
3. `op X : -> WasmTerminal` 과 `var X : WasmTerminal` 이 같은 이름으로 공존하면 `op` 선언 제거 → op/var ambiguity 차단.

---

### 1.3 `texpr` 레코드 : Pure Functional State

```ocaml
type texpr = { text : string; vars : string list }
```

모든 표현식(expression) 변환은 다음을 포함하는 `texpr` 레코드를 반환한다.

- **`text`**: 생성된 Maude 소스 코드 조각
- **`vars`**: AST 순회 중 발견된 변수명 리스트 (나중에 `vars` 선언 및 `:=` 바인딩 스케줄링에 사용됨)

이를 통해 표현식을 변환할 때 전역 가변 누산기(global mutable accumulator)를 사용할 필요가 사라진다. 변수들은 아래의 콤비네이터들을 통해 상위로 전달(propagate)된다.

```ocaml
tconcat : string → texpr list → texpr       (* 구분자로 연결 *)
tmap    : (string → string) → texpr → texpr (* 텍스트만 변환 *)
tjoin2  : (string → string → string) → texpr → texpr → texpr
tjoin3  : ... → texpr → texpr → texpr → texpr
```

> **예시 : `BinE(AddOp, VarE "a", VarE "b")` 변환**
>
> **Step 1**: 왼쪽 자식 노드 `VarE("a")` 변환
> 전역 변수를 건드리는 대신, 자기 자신이 발견한 변수를 `texpr` 레코드에 담아서 위로 던진다.
> → 반환값: `{ text = "A"; vars = ["A"] }`
>
> **Step 2**: 오른쪽 자식 노드 `VarE("b")` 변환
> → 반환값: `{ text = "B"; vars = ["B"] }`
>
> **Step 3**: 부모 노드 `BinE(AddOp, ...)` 변환 (콤비네이터)
> 부모 노드는 밑에서 올라온 두 개의 `texpr`을 받아 `tjoin2`로 하나의 큰 `texpr`로 합친다.
> → 최종 반환값: `{ text = "( A + B )"; vars = ["A", "B"] }`
>
> **함수들의 역할:**
> - `tjoin2` : `a + b` 처럼 항상 2개인 이항 연산 처리
> - `tmap` : `(a)` 나 `-a` 처럼 하나의 식을 괄호로 감싸거나 부호를 붙일 때
> - `tconcat` : `f(a, b, c, ...)` 처럼 인자가 몇 개일지 모르는 리스트를 콤마(`,`)나 공백으로 이어 붙일 때

---

### 1.4 Declaration Management

변수 및 연산자의 중복 선언 오류를 방지하기 위해 `declared_vars` 해시 테이블을 활용하여 선언 이력을 추적한다. 특히, Maude 헤더에 이미 정의된 기본 변수들 (`I`, `W-I`, `W-N`, `W-M`, `T`, `W`, `WW`, `TS`, `W*`)은 `init_declared_vars()`를 통해 사전에 등록(초기화)함으로써 중복 방출을 차단한다.

여러 변수를 한꺼번에 선언할 때는 `declare_vars_same_sort`가 `vars X Y Z : WasmTerminal .` 형태의 단일 선언을 생성하여 출력 파일 크기를 줄인다.

자유(free) 변수 — rule 전제에만 등장하고 결론 LHS 에는 없는 변수 — 는 Skolem 상수로 취급하여 `op X : -> WasmTerminal .` 로 선언한다(`declare_ops_const_list`).

---

### 1.5 Variable Prefixing : Assoc-Tail Collision 방지

Maude의 `assoc id:` 속성을 가진 연산자(특히 `WasmTerminals`의 `_ _`)에서, 여러 방정식이 동일한 이름을 assoc tail 변수로 사용하면 **coherence checker 가 잘못된 interaction을 감지**하여 일부 방정식이 점화(fire)되지 않는 버그가 발생한다 (상세는 `architecture_decisions.md §B` 참조).

`make_var_prefix` 함수는 모든 변수에 `{REL}-{CASE}{IDX}-{NAME}` 형태의 고유 접두사를 붙여 충돌을 원천 차단한다. 예:

```
Step-pure / binop-val rule, eq_idx=3, binder "c"
→ STEP-PURE-BINOP-VAL3-C
```

숫자는 alpha 로 매핑 (`0→P, 1→Q, ..., 9→Y`) 하여 Maude 식별자 규칙을 만족시킨다.

---

## 2. Formal Translation Rules

다음 규칙들은 SpecTec IL AST 노드에서 Maude 선언 및 방정식으로의 매핑을 정의한다.

**표기법**: `⟦ AST_node ⟧ ⟹ Maude_output`

여기서 `⟦...⟧`는 변환 함수를, `⟹`는 "생성한다(produces)"를 의미한다.

---

### 2.1 syntax (TypD)

```
[[ TypD (id, params, insts) ]] =>

    --- 소트 선언 (비-파라메트릭, non-builtin, non-base-type 인 경우)
    sort sort_of_type_name(id) .
    subsort sort_of_type_name(id) < WasmType .

    --- 생성자 op (순수 메타 변수 N, M, K, n, m 은 제외)
    op sanitize(id) : WasmTerminal^|params| -> WasmType [ctor] .

    insts 내의 각 InstD(binders, args, deftyp)에 대해 :

        let v_map        = binder_var_map(binders)
        let binder_conds = binder_type_conds(binders)
        let type_term    = mk_type_term(args, v_map)    --- 예: "numtype"  또는  "binop(NT)"
        let full_sort    = sort_of_type_name(id)

        if deftyp == VariantT(cases) :

            cases 내의 각 (mixop, (_, case_typ, prems), _)에 대해 :

                let params = collect_params(case_typ)  --- [(var_name, guard, maude_sort)]
                let N      = |params|

                (V_1 ... V_N : 각 파라미터의 원래 타입 이름을 대문자화 + counter 인덱스
                              iteration list 는 WasmTerminals 로, 그 외는 WasmTerminal 로 선언)

                canonical-ctor = canonical_ctor_name_arity(mixop, N)
                                = "CTOR<mixop의 compact 영숫자>A<N>"

                --- [패턴 1] 단순 키워드 (인자 없음, N = 0)
                if N == 0 and prems == [] :
                    => op CTOR<...>A0 : -> WasmTerminal [ctor] .     --- 자동 수집 + canonical decl
                       mb ( CTOR<...>A0 ) : full_sort .

                --- [패턴 2] 인자 포함 (N > 0, 전제 없음)
                else if N > 0 and prems == [] and OptT ∉ case_typ :
                    => op CTOR<...>AN : arg_sort_1 ... arg_sort_N -> WasmTerminal [ctor] .
                       cmb ( CTOR<...>AN ( V_1, ..., V_N ) ) : full_sort
                         if type-check(V_1, S_1) ... .

                --- [패턴 3] optional parameter (case_typ 에 IterT(_, Opt) 포함)
                    각 옵셔널 파라미터 자리를 'eps' 로 치환한 보조 방정식을 추가로 발행.
                    --- ex :
                        --- spectec : syntax instr = | IF blocktype?
                        --- Maude  : cmb ( CTORIFA1 ( BLOCKTYPE1 ) ) : instr
                        ---             if type-check(BLOCKTYPE1, blocktype) .
                        ---          mb  ( CTORIFA1 ( eps ) ) : instr .

                --- [패턴 4] 전제조건 있음 (prems ≠ [])
                else :
                    => 스케줄링된 전제들 (match-binding 먼저, bool 나중) 을 and 로 연결한
                       조건부 cmb 발행.

                --- [패턴 5] 파라메트릭 타입 (is_parametric = true, 예: binop_(Inn))
                    Maude 의 sort membership 대신 type-ok 연산자 사용:
                    => ceq type-ok ( lhs , type_term ) = true
                         if binder_conds and param_guards .

        if deftyp == AliasT(typ) :
            let lhs_var = (id 가 iterative list 타입이면 "TS", 그 외는 "T")
            let alias_guard = type-check(lhs_var, typ)
            => mb  ( lhs_var ) : full_sort                  --- 전제 없을 때
             | cmb ( lhs_var ) : full_sort if alias_guard . --- 전제 있을 때

        if deftyp == StructT(fields) :
            각 필드 f_i 에 대해 F-{f_i}-{index} 라는 임시 변수명 부여.
            => cmb ( { item('F_1, ( V_1 )) ; ... ; item('F_n, ( V_n )) } ) : full_sort
                 if type-check(V_1, S_1) and ... and type-check(V_n, S_n) .
```

**주의**: `is-type` (구 버전) 과 `type-check` / membership axiom 의 차이
- **비-파라메트릭 타입**: Maude 의 **멤버십 (`mb` / `cmb` : )** 으로 발행. `T : numtype = true` 형태가 아니라 `T : Numtype` 소트 판정.
- **파라메트릭 타입** (예: `binop_(Inn)`): 소트 시스템으로 표현 불가능하므로 `type-ok(V, binop(NT))` Bool 연산자로 폴백.

---

### 2.2 def (DecD)

```
[[ DecD(id, params, result_typ, insts) ]] =>

    let fn       = "$" ^ sanitize(id)
    let prefix   = 대문자화된 id 의 첫 하이픈-분할 토큰 (예: "binop" → "BINOP")
    let ret_sort = result_typ 이 IterT(_, List|List1)   → "WasmTerminals"
                 | result_typ 이 Bool / boolish        → "Bool"
                 | 이외                                → declared_sort_of_typ(result_typ)

    op fn : arg_sort_1 ... arg_sort_n -> ret_sort .

    insts 내의 각 DefD(binders, lhs_args, rhs, prems) (eq_idx 번째) 에 대해 :

        --- vm (Var Map) : SpecTec 변수를 Maude 변수로 바꿔주는 '변환 사전'
        --- (ex : "c" 라는 변수가 0번 규칙에서 나오면 "BINOP0-C" 로, 1번 규칙이면 "BINOP1-C" 로
        ---  고유 접두사를 붙여서 겹치지 않게 해 줌)
        vm = binder_to_var_map(prefix, eq_idx, binders)

        LHS     = fn(translate_exp(TermCtx, lhs_args, vm))
        RHS     = translate_exp(rhs_ctx, rhs, vm)
              --- rhs_ctx = BoolCtx  if ret_sort == "Bool" else TermCtx
        COND    = schedule_prems(lhs_bound_vars, prem_items) 의 조건부 join

        bound   = LHS/prems 에 등장하는 변수 (이미 prem 으로 바인딩된 것 포함)
                 => vars <bound> : WasmTerminal . (단일 선언으로 묶음)
        free    = RHS/prems 에만 등장하는 변수
                 => op <free> : -> WasmTerminal . (Skolem 상수)

        if COND == "" :  eq  LHS = RHS [owise?] .
        else          :  ceq LHS = RHS if COND [owise?] .
```

**prem 스케줄링 (`schedule_prems`)**: 모든 전제를 `PremBool` / `PremEq` 로 분류한 후 위상정렬한다. `PremEq { lhs ; rhs }` 는 다음 네 케이스로 처리된다.

| LHS 변수 | RHS 변수 | 분류 | 생성되는 Maude 조건 |
|---|---|---|---|
| 미바인딩 | 모두 바인딩됨 | `:=` binding | `lhs := rhs` (LHS 변수들을 bound 로 승격) |
| 모두 바인딩됨 | 미바인딩 | `:=` binding (역방향) | `rhs := lhs` |
| 둘 다 바인딩됨 | 둘 다 바인딩됨 | boolean test | `( lhs == rhs ) = true` |
| 스케줄 불가 | 스케줄 불가 | forced (순서 포기) | bool 테스트로 강제 emit |

---

### 2.3 Rule (RelD)

`RelD` 는 관계 이름에 따라 두 가지 경로로 분기된다.

#### 2.3.1 일반 관계 (`translate_reld`)

Typing / Validation / Subtyping 등 **Bool 반환 관계** 는 `ceq Rel(args) = true if COND` 형태로 번역된다.

```
[[ RelD(id, _, _, rules) ]] =>
   (단, id 가 "Step"/"Step-pure"/"Step-read" 가 아닐 때)

    let rel_name = sanitize(id)
    let arity    = conclusion 의 TupE 자식 개수

    op rel_name : WasmTerminal^arity -> Bool .

    rules 내의 각 RuleD(case_id, binders, _, conclusion, prems) (rule_idx 번째)에 대해 :

        --- 전제에 Step/Step-pure/Step-read 를 Bool 로 참조하는 RulePr 이 있으면 skip
        --- (Step 계열은 Bool 이 아니라 등식 step() 함수로 번역되므로 조건절 불가능)
        if has_step_exec_rule_premise(prems) : continue

        let prefix = "{REL}-{CASE}"
        vm         = binder_to_var_map(prefix, rule_idx, binders)
        ARGS       = translate_exp(TermCtx, conclusion_args, vm)   --- 콤마 구분
        COND       = schedule_prems(lhs_vars ∪ non-binding vm_vars, prem_items)

        bound = vars in conclusion ∪ non-binding vm_vars  => vars 선언
        free  = 전제에만 등장하는 변수                    => op 상수 선언 (스콜렘)

        if COND == "" :  eq  rel_name ( ARGS ) = true .
        else          :  ceq rel_name ( ARGS ) = true if COND .
```

#### 2.3.2 실행 의미론 관계 (`translate_step_reld`)

`Step`, `Step-pure`, `Step-read` 이름의 관계는 **Bool ceq 로 번역할 수 없고, 대신 Maude 의 등식 `step` 함수에 대한 방정식을 생성** 한다.

```
[[ RelD(id="Step" | "Step-pure" | "Step-read", _, _, rules) ]] =>

    rules 내의 각 RuleD(case_id, binders, _, conclusion, prems) (rule_idx 번째) 에 대해 :

        --- 브리지/컨텍스트 규칙은 skip (wasm-exec.maude 가 heating/cooling 으로 처리)
        if has_rule_premise(prems) : continue

        let prefix = "{REL}-{CASE}"
        let is_var = "{prefix}-IS"                --- 이 규칙 고유의 continuation 변수
        vm         = binder_to_var_map(prefix, rule_idx, binders)

        --- conclusion 디코딩 (관계 종류에 따라 다름)
        case id :
          Step-pure :
            --- conclusion = TupE [lhs_instrs , rhs_instrs]   (state 없음)
            z_in  = z_out = "{prefix}-Z"  (신선 변수)
            lhs_t = translate_exp(lhs_instrs)
            rhs_t = translate_exp(rhs_instrs)

          Step-read :
            --- conclusion = TupE [ z ; lhs_instrs , rhs_instrs ]
            try_decompose_config(cfg_lhs) → (z_e, lhs_e)
            z_in  = z_out = translate(z_e)
            lhs_t = translate(lhs_e)
            rhs_t = translate(rhs_instrs)

          Step :
            --- conclusion = TupE [ z ; lhs , z' ; rhs ]
            try_decompose_config(cfg_lhs) → (z_e,  lhs_e)
            try_decompose_config(cfg_rhs) → (zp_e, rhs_e)
            z_in  = translate(z_e)
            z_out = translate(zp_e)
            lhs_t = translate(lhs_e)
            rhs_t = translate(rhs_e)

        COND = schedule_prems(z_in_vars ∪ lhs_vars ∪ non-binding vm_vars, prem_items)

        [c]eq step(< z_in | lhs_t is_var >) = < z_out | rhs_t is_var > [if COND] .
```

여기서 `is_var` 는 각 규칙마다 **고유** 한 `WasmTerminals` 변수로, assoc-tail 역할을 한다. 동일한 이름이 다른 관계의 `step` 방정식에서 쓰이면 coherence checker 가 고장나므로 `{REL}-{CASE}-IS` 형태로 고유 네이밍을 강제한다.

#### 2.3.3 `config` 분해 (`try_decompose_config`)

```ocaml
let try_decompose_config (e : exp) =
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

SpecTec IL 에서 `z ; instr*` 는 `CaseE(semicolon_mixop, TupE [z_e; instr_e])` 로 표현된다. canonical ctor 이름이 `CTORSEMICOLONA2` 일 때 두 인자를 추출한다.

> **💡 혁순선배 로직과의 차이**
>
> **SpecTec 원문:**
> ```
> rule Step_pure/binop-val:
>   (CONST nt c_1) (CONST nt c_2) (BINOP nt binop)  ~>  (CONST nt c)
>   -- if c <- $binop_(nt, binop, c_1, c_2)
> ```
> *의미: CONST 2개랑 BINOP 1개가 연달아 있으면, 그걸 계산해서 하나의 CONST로 바꿈*
>
> ---
>
> **전제 조건 & 상태(Context)에서의 차이**
>
> **선배의 수동 변환 코드** — `⇒ (상태가 변한다)` 기호를 사용:
>
> ```maude
> crl [binop-val] : stage:(
>     STATE_BINOP_VAL ; (VALS (CONST NT_BINOP_VAL C_1_BINOP_VAL)
>                             (CONST NT_BINOP_VAL C_2_BINOP_VAL)
>                             (BINOP NT_BINOP_VAL BINOP_BINOP_VAL) INSTRS)
>    ) => stage:(
>    STATE_BINOP_VAL ; (VALS (CONST NT_BINOP_VAL C_BINOP_VAL) INSTRS)
>    )
> ```
>
> **문제점**: SpecTec 원문에는 `STATE_BINOP_VAL`, `VALS`, `INSTRS` 같은 단어가 단 한 개도 없음.
> 그런데 선배는 "실제로 프로그램이 굴러가려면 메모리도 있어야 하고, 뒤에 다른 명령어도 있겠지?"라고 상상해서
> 가짜 환경(Context)을 강제로 끼워 넣음 → 명세서 원본의 형태가 심하게 훼손됨.
>
> **나의 자동 변환 코드** — `step` 등식 함수와 per-rule continuation 변수 `IS` 를 사용:
>
> ```maude
> ceq step(< STEP-PURE-BINOP-VAL-Z |
>            CTORCONSTA2(STEP-PURE-BINOP-VALP-NT, STEP-PURE-BINOP-VALP-C1)
>            CTORCONSTA2(STEP-PURE-BINOP-VALP-NT, STEP-PURE-BINOP-VALP-C2)
>            CTORBINOPA2(STEP-PURE-BINOP-VALP-NT, STEP-PURE-BINOP-VALP-BINOP)
>            STEP-PURE-BINOP-VAL-IS >)
>    = < STEP-PURE-BINOP-VAL-Z |
>        CTORCONSTA2(STEP-PURE-BINOP-VALP-NT, STEP-PURE-BINOP-VALP-C)
>        STEP-PURE-BINOP-VAL-IS >
>    if STEP-PURE-BINOP-VALP-C := $binop(STEP-PURE-BINOP-VALP-NT,
>                                         STEP-PURE-BINOP-VALP-BINOP,
>                                         STEP-PURE-BINOP-VALP-C1,
>                                         STEP-PURE-BINOP-VALP-C2) .
> ```
>
> **잘한 점**:
> 1. 원본 AST 구조(`CONST nt c_1 CONST nt c_2 BINOP nt binop`)를 CTOR 이름만 바꾼 채로 **100% 정직하게** 옮겨옴.
> 2. 모든 변수명에 `{REL}-{CASE}{IDX}` 고유 접두사가 붙어 assoc-tail collision 원천 차단.
> 3. 전제의 `c <- $binop(...)` 가 자동으로 `:= $binop(...)` (Maude의 match-binding) 으로 번역됨. 스케줄러가 `c` 가 미바인딩 변수임을 감지하고 방향을 결정.
>
> ---
>
> **핵심 : 스택 머신의 구현 위치 차이**
>
> - **혁순선배** : 번역된 코드 한가운데에 스택 구조(`VALS`, `INSTRS`)를 욱여넣음.
>   Wasm 명세가 바뀌면 사람이 일일이 스택 구조를 다시 손으로 짜서 맞춰야 함.
>
> - **나의 방식** : 변환된 코드(`output.maude`)에는 순수하게 수학 공식(`ceq step(...) = ...`)만 남겨두고,
>   스택 머신·평가 문맥 (eval context) 을 돌리는 역할은 완전히 별도의 파일(`wasm-exec.maude`)로 분리.
>
> ```maude
> --- wasm-exec.maude : heating/cooling 패턴 (SpecTec 의 Step/ctxt-label 규칙 대응)
> ceq step(< ST-Z | exec-label(ST-AR, ST-IS0, ST-ISB) ST-IS >)
>     = restore-label(step(< ST-Z | ST-ISB >), ST-AR, ST-IS0, ST-IS)
>     if all-vals(ST-ISB) = false /\ is-trap(ST-ISB) = false .
>
> eq restore-label(< RL-ZN | RL-ISBN >, RL-AR, RL-IS0, RL-IS)
>    = < RL-ZN | exec-label(RL-AR, RL-IS0, RL-ISBN) RL-IS > .
> ```
>
> - **선배의 방식 (일체형)**: 수학 연산과 스택 머신을 한 덩어리로 통째로 용접. 엔진만 바꾸고 싶어도 차를 다 부숴야 함.
> - **나의 방식 (분리형)**: 변환기는 수학 연산만 찍어냄. 스택 엔진은 따로 만들어서 수학 연산만 끼워 넣게 만듦.

---

### 2.4 Translation Rules Summary

| Category | SpecTec (Input) | IL (AST) | Maude (Output) |
|---|---|---|---|
| 단순 합타입 | `syntax T = C` | `TypD("T", [], [InstD(..., VariantT([("C", ..., [], ...)]))])` | `op CTORCA0 : -> WasmTerminal [ctor] .`<br>`mb ( CTORCA0 ) : T .` |
| 인자 포함 합타입 | `syntax T = C P` | `TypD("T", ..., VariantT([("C", ..., [P], ...)]))` | `op CTORCA1 : WasmTerminal -> WasmTerminal [ctor] .`<br>`cmb ( CTORCA1 ( V ) ) : T if type-check(V, P) .` |
| 타입 별칭 | `syntax T1 = T2` | `TypD("T1", [], [InstD(..., AliasT(T2))])` | `cmb ( T ) : T1 if type-check(T, T2) .` |
| 구조체 타입 | `syntax T = {f: P}` | `TypD("T", ..., StructT([("f", P)]))` | `cmb ( { item('F, ( V1 )) } ) : T if type-check(V1, P) .` |
| 파라메트릭 타입 | `syntax T(A) = C P` | `TypD("T", [A], ..., VariantT(...))` | `op T : WasmTerminal -> WasmType [ctor] .`<br>`ceq type-ok ( CTORCA1 ( V ) , T ( A ) ) = true if ... .` |
| 옵셔널 파라미터 | `syntax T = C P?` | `TypD(..., VariantT(..., [IterT(P, Opt)], ...))` | `cmb ( CTORCA1 ( V ) ) : T if type-check(V, P) .`<br>`mb  ( CTORCA1 ( eps ) ) : T .` |
| 단순 함수 정의 | `def $f(x) = e` | `DecD("f", ..., [DefD([], [VarE "x"], e_ast, [])])` | `op $f : WasmTerminal -> WasmTerminal .`<br>`eq $f ( X ) = translate(e) .` |
| 종속 타입 함수 | `def $f(x: T1, y: T2(x)) = e` | `DecD("f", ..., [DefD(binders, lhs, e_ast, [])])` | `op $f : WasmTerminal WasmTerminal -> WasmTerminal .`<br>`vars F0-X F0-Y : WasmTerminal .`<br>`ceq $f ( F0-X , F0-Y ) = translate(e)`<br>&nbsp;&nbsp;`if type-check(F0-X, T1) and type-check(F0-Y, T2(F0-X)) .` |
| 일반 관계 | `rule R/case: LHS`<br>`-- if prems` | `RelD("R", ..., [RuleD("case", ..., conclusion, prems)])` | `op R : WasmTerminal^arity -> Bool .`<br>`vars R-CASE-... : WasmTerminal .`<br>`ceq R ( ARGS ) = true if COND .` |
| 실행 의미론 (Step-pure) | `rule Step_pure/c:`<br>`lhs ~>_pure rhs` | `RelD("Step-pure", ..., [RuleD("c", ..., TupE[lhs, rhs], prems)])` | `vars STEP-PURE-C-Z : WasmTerminal .`<br>`var  STEP-PURE-C-IS : WasmTerminals .`<br>`[c]eq step(< Z \| LHS IS >) = < Z \| RHS IS > [if COND] .` |
| 실행 의미론 (Step-read) | `rule Step_read/c:`<br>`z;lhs ~>_read rhs` | `RelD("Step-read", ..., [RuleD("c", ..., TupE[<z ; lhs>, rhs], prems)])` | `[c]eq step(< Z \| LHS IS >) = < Z \| RHS IS > [if COND] .` |
| 실행 의미론 (Step) | `rule Step/c:`<br>`z;lhs ~> z';rhs` | `RelD("Step", ..., [RuleD("c", ..., TupE[<z ; lhs>, <z' ; rhs>], prems)])` | `[c]eq step(< Z \| LHS IS >) = < Z' \| RHS IS > [if COND] .` |

---

## 3. Helper Rules

### 3.1 `translate_exp`

SpecTec 표현식을 Maude 텍스트로 변환한다. `ctx ∈ {BoolCtx, TermCtx}`에 따라 Boolean 래핑이 달라진다.

```
[[ translate_exp(ctx, e, vm) ]] =>
    match e:
        VarE id:
            resolve_var_name(id, vm) → mapped (var_map 조회, case-insensitive, suffix 해결)
            else if "true"/"false" → wrap_bool(ctx, ...)
            else if token-like (대문자 시작, 2글자 이상, 예약어 아님) → sanitize(id)
            else → to_var_name(id) (UPPERCASE + sanitize)

        NumE n: Z.to_string(n) 또는 "num/den" 또는 "%.17g"
        BoolE b: wrap_bool(ctx, "true"/"false")
        TextE s: "\"" ^ s ^ "\""

        CaseE(mixop, inner):
            if mixop = "$" | "%" | "" → translate_exp(inner) (트랜스페어런트)
            else:
                arg_texts = translate_exp(TermCtx) each inner child
                canonical = canonical_ctor_name_arity(mixop, arity)
                if canonical = Some(CTOR...A<n>) → format_call(CTOR...A<n>, args)
                else → sections 와 args 교차 배치 (sect1 V1 sect2 V2 ...)

        CallE(id, args):
            format_call(call_name(id), translate_arg(args))
            --- call_name("foo")    = "$foo"
            --- call_name("$foo")   = "$foo"
            --- call_name("$")      = "w-$" (special transparent)

        BinE(op, _, e1, e2):  ( translate(e1) <op_str> translate(e2) )
            Arithmetic ops:  +, -, *, quo, rem, ^         (TermCtx sub-ctx)
            Boolean   ops: and, or, implies, == (EquivOp) (BoolCtx sub-ctx, wrap_bool 반환)
        CmpE(op, _, e1, e2): wrap_bool(ctx, ( e1 <cmp> e2 ))
        UnE(NotOp, _, e1):   wrap_bool(ctx, not ( e1 ))
        UnE(MinusOp, _, e1): ( 0 - ( e1 ) )
        UnE(PlusOp, _, e1):  translate_exp(e1)

        StrE fields:  { item('F1, v1) ; item('F2, v2) ; ... }
        DotE(e, atom): value('ATOM, translate(e))

        TupE [] | ListE []: eps
        TupE [e1]:          translate_exp(e1)
        TupE el | ListE el: translate_exp(e1) " " ... " " translate_exp(en)

        IfE(c, e1, e2): if translate(BoolCtx, c) then translate(e1) else translate(e2) fi
        MemE(e1, e2):   wrap_bool(ctx, ( e1 <- e2 ))       --- SpecTec 집합 멤버십
        CompE(e1, e2):  merge ( e1 , e2 )
        CatE(e1, e2):   e1 e2                              --- WasmTerminals 연결
        LenE(e1):       len ( e1 )
        IdxE(e1, e2):   index ( e1, e2 )
        SliceE(e1, e2, e3): slice ( e1, e2, e3 )
        UpdE(e1, path, e2): ( e1 [<bracket> path <- e2 ] )  --- path 가 qid 면 "[.", 아니면 "["
        ExtE(e1, path, e2): ( e1 [<bracket> path =++ e2 ] )

        IterE(VarE id, (List|List1|Opt, _)):
            suffix = "*" | "+" | "?"
            resolve_var_name(id ^ suffix, vm) → mapped
                --- vm 에 등록된 binder 의 iter-suffixed alias 찾음
                --- 예: binder_to_var_map 이 ("foo*", mapped) 를 자동 등록
            else → UPPERCASE(sanitize(id ^ suffix))
        OptE None:          eps
        OptE Some e1 | TheE e1 | LiftE e1: translate_exp(e1)
        CvtE | SubE | ProjE | UncaseE: translate_exp(inner)  (트랜스페어런트)
```

**`resolve_var_name` 의 3단계 조회**:
1. `find_vm_case_insensitive`: vm 에서 대소문자 무시하고 직접 검색
2. `resolve_suffixed`: `"numtype_2"` 같은 인덱스 접미사를 base + index 로 분해하여 vm 의 여러 `numtype` 엔트리 중 2번째 매치
3. `strip_iter_suffix`: `"foo*"` → `"foo"` 로 iter 접미사 제거 후 재시도

---

### 3.2 `translate_prem`

| Prem 노드 | 변환 |
|---|---|
| `IfPr e` | `translate_exp(BoolCtx, e)` ; `collect_prem_items_of_exp` 로 AND-conjunction 분해하여 각 `CmpE(EqOp, ...)` / `MemE(...)` 를 독립 `PremEq` 로 분리 |
| `RulePr(id, _, e)` | `format_call(sanitize(id), translate_exp(args))` (단, Step-계열 RulePr 은 상위에서 skip) |
| `LetPr(e1, e2, _)` | `PremEq{ lhs = translate(e1); rhs = translate(e2) }` → 스케줄러가 `:=` 방향 결정 |
| `ElsePr` | `owise` 속성 (조건이 아닌 방정식 속성으로 처리) |
| `IterPr(inner, _)` | `translate_prem(inner)` (iteration context 는 무시) |
| `NegPr inner` | `translate_prem(inner)` (부정은 현재 조건에 반영되지 않음 — TODO) |

**Prem 분류 (`prem_items_of_prem` → `PremBool` / `PremEq`)**: `PremEq` 는 LHS/RHS 변수 바인딩 상태에 따라 `:=` 방향을 결정. 어느 쪽도 스케줄 불가능하면 `bool_t = (lhs == rhs) = true` 로 폴백.

---

### 3.3 `translate_arg`

| Arg 노드 | 변환 |
|---|---|
| `ExpA e` | `translate_exp(TermCtx, e)` |
| `TypA t` | `translate_typ(t)` |
| `DefA _` | `eps` |
| `GramA _` | `eps` |

---

### 3.4 `translate_typ`

| Typ 노드 | 변환 |
|---|---|
| `VarT(id, [])` | vm 에 매핑 있고 대문자가 아니면 mapped, 아니면 `sanitize(id)` |
| `VarT(id, args)` | `sanitize(id) ( arg1 , arg2 , ... )` |
| `IterT(inner, _)` | `translate_typ(inner)` (iteration 무시) |
| 기타 | `WasmType` |

---

### 3.5 `sanitize`

| 조건 | 변환 |
|---|---|
| `"_"` | `any` |
| 단일 문자, 비알파벳 시작 (단 `$` 제외), Maude 키워드 (`if`/`var`/`op`/`eq`/`sort`/`mod`/`quo`/`rem`/`or`/`and`/`not`) | `w-` prefix |
| `. _ * + ?` | `-` 로 치환 |
| `'` (apostrophe) | `Q` 로 치환 |
| `-<digit>` 시퀀스 | `N<digit>` 으로 치환 |
| 후행 하이픈 | 반복 제거 |

예: `numtype_2` → `numtypeN2`, `$iadd_` → `$iadd`, `IF'` → `IFQ`, `nop` → `w-nop` (`nop` 이 Maude 예약어는 아니지만 단일 문자 시작 규칙에 걸리지 않으므로 그대로 통과 — 실제로는 통과함)

---

### 3.6 `wrap_bool` (Boolean 래핑)

```
wrap_bool(BoolCtx, s) = s
wrap_bool(TermCtx, s) = w-bool ( s )
```

- **Boolean 맥락 (`BoolCtx`)**: `IfPr`, `and`/`or`/`implies`/`== (EquivOp)`, `not`, Bool 반환 함수의 RHS, `translate_prem` 내부.
- **Term 맥락 (`TermCtx`)**: 그 외 모든 곳 (생성자 인자, 구조체 필드, 튜플 원소, 산술 연산 등).

`w-bool` 은 헤더에서 `op w-bool : Bool -> WasmTerminal [ctor]` 로 선언된 래퍼로, Bool 값이 `WasmTerminal` 자리에 들어가야 할 때 kind 불일치를 막는다.

---

### 3.7 `canonical_ctor_name_arity`

```ocaml
let canonical_ctor_name_arity mixop arity =
  let atoms =
    mixop_sections mixop
    |> filter nonempty
    |> filter (not "%") (not "$")
    |> map compact_alnum
    |> filter nonempty
  in
  Some (Printf.sprintf "CTOR%sA%d" (String.concat "" atoms) arity)
```

mixop 을 구성하는 원자들의 영숫자만 남겨 대문자로 합친 후 arity 를 붙여 canonical 이름을 생성한다.

- `mixop = [["LOCAL"; "."; "GET"]]`, arity=1 → `CTORLOCALGETA1`
- `mixop = [["CONST"]]`, arity=2            → `CTORCONSTA2`
- `mixop = [[";"]]`, arity=2                → `CTORSEMICOLONA2`

이 규칙은 mixop 원자의 소스 위치·수와 무관하게 **같은 연산자에 대해 항상 같은 이름** 을 생성하므로, 번역기 어디서든 (expression 변환, `try_decompose_config`, canonical ctor decl 수집 등) 동일 이름으로 참조 가능하다.

---

## 4. Sort 계층 구조 및 파싱 모호성 분석

### 4.1 The Flat Sort Lattice

생성된 명세는 의도적으로 평탄한 소트 계층 구조를 사용한다.

```
       WasmTerminals
       /          \
WasmTerminal    (assoc juxtaposition _ _)
  /   |   \
Int  Nat  WasmType
```

```maude
subsort Int < WasmTerminal .
subsort Nat < WasmTerminal .
subsort WasmType < WasmTerminal .
subsort WasmTypes < WasmTerminals .
subsort WasmTerminal < WasmTerminals .   --- DSL-PRETYPE
```

모든 파라메트릭이 아닌 syntax 정의마다 개별 sort + `subsort <S> < WasmType` 을 발행하지만, 평가(rewriting) 는 항상 `WasmTerminal` / `WasmTerminals` kind 에서 일어난다.

---

### 4.2 Source of Ambiguity

항(term)이 여러 소트 수준에서 파싱될 수 있을 때, Maude는 `Warning: multiple distinct parses` 경고를 보고한다. 이는 두 가지 메커니즘에서 발생한다.

**메커니즘 A : 오버로딩된 상수 (Overloaded Constants)**

`CTORNOPA0` 과 같은 생성자는 두 경로로 선언될 수 있다.
- 토큰 프리스캔: `ops ... CTORNOPA0 ... : -> WasmTerminal [ctor] .`
- canonical ctor 재수집: `op CTORNOPA0 : -> WasmTerminal [ctor] .`

두 선언 모두 동일한 op signature 를 만들므로 Maude 가 이를 두 개의 별개 파싱 대안으로 간주한다. 후처리 단계의 중복 제거가 대부분 해결하지만 일부 케이스에서 경고가 남는다.

**메커니즘 B: 하위 소트 다형성 (Subsort Polymorphism)**

정수 리터럴 `42` 는 다음과 같이 파싱될 수 있다.
- `42 : Nat` (내장 타입을 통해)
- `42 : Int` (`subsort Nat < Int`를 통해)
- `42 : WasmTerminal` (`subsort Int < WasmTerminal` 을 통해)

`type-check(42, num(CTORI32A0))` 의 인자로 `42` 가 등장할 때, 파서는 각 소트 수준에서 유효한 파싱 결과를 본다.

---

### 4.3 Confluence Argument

**Claim**: All ambiguous parses of a well-formed term in SPECTEC-CORE yield identical rewriting behavior.

**Proof sketch:**

1. **Sort Monotonicity.** For any operator `f : S₁ → S₂` with `S₁ ⊂ S₁'`, if a term `t` has sort `S₁`, then `f(t)` computed at sort `S₁` equals `f(t)` computed at sort `S₁'`. This holds because all equations in SPECTEC-CORE are defined at the maximal sort (`WasmTerminal` / `WasmTerminals`), and Maude's equational matching operates at the kind level `[WasmTerminal]`, which subsumes all subsorts.

2. **Operator Idempotence.** Duplicate `op` declarations for the same name with identical signature and attributes produce the same constructor in Maude's internal representation. The two parse trees are syntactically distinct but semantically identical — they denote the same term in the term algebra `T_Σ/E`.

3. **Equational Convergence.** All equations (`eq`/`ceq`) pattern-match at the kind level. A conditional equation `ceq f(X) = rhs if cond` will match any term of kind `[WasmTerminal]` regardless of which subsort parse was chosen. Since the matched substitution `σ` maps variables to the same ground values in all parses, the rewriting result is unique.

4. **Church-Rosser Property.** Maude's equational engine is Church-Rosser modulo the declared axioms (associativity, identity). Since our equations do not introduce competing rewrites for the same LHS pattern (the flat sort hierarchy prevents sort-based equation selection), the system is confluent.

**Practical Implication**: `fib(5)` 실행 중 5,949 rewrites 가 결정적으로 수렴하며, 같은 입력에 대한 LTL 모델 체크 결과도 반복 재현된다는 실증적 증거가 위 수학적 논변을 뒷받침한다.

---

### 4.4 Why a Flat Hierarchy?

A richer sort hierarchy (e.g., `sort numtype . subsort numtype < valtype . subsort valtype < WasmTerminal .`) would eliminate many ambiguity warnings but would require:

- Complete sort inference from the SpecTec type system, which uses dependent types and type-indexed families not directly expressible in Maude's order-sorted algebra. (예: `binop_(Inn)` — `Inn` 자체가 `numtype` 중 정수 타입만을 한정하는 dependent index.)
- Cross-cutting subsort declarations for Wasm's overlapping type categories (e.g., `I32` is simultaneously a `numtype`, an `Inn`, an `addrtype`, and a `valtype`).

The flat hierarchy trades parsing precision for translation generality: any SpecTec type maps uniformly to `WasmTerminal`, and type membership is encoded equationally via `type-check` / membership axiom. This is a deliberate design choice that prioritizes completeness of the translation over elimination of advisory warnings.

---

## Appendix A : Examples

### A.1 syntax (TypD)

#### VariantT - 패턴 1: 단순 키워드 (`numtype`)

**SpecTec:**
```
syntax numtype = | I32 | I64
```

**IL:**
```ocaml
TypD (id "numtype", [], [
  InstD ([], [], VariantT [
    (["I32"], ([], TupT [], []), []);
    (["I64"], ([], TupT [], []), [])
  ])
]);
```

**Maude:**
```maude
sort Numtype .
subsort Numtype < WasmType .
op numtype : -> WasmType [ctor] .

op CTORI32A0 : -> WasmTerminal [ctor] .
mb ( CTORI32A0 ) : Numtype .
op CTORI64A0 : -> WasmTerminal [ctor] .
mb ( CTORI64A0 ) : Numtype .
```

---

#### VariantT - 패턴 2: 인자 포함 (`CONST`)

**SpecTec:**
```
syntax instr = | CONST numtype num_(numtype)
```

**IL:**
```ocaml
TypD ("instr", [], [
    InstD ([], [], VariantT [
      (["CONST"; ""], ([], TupT [
        (dummy_lbl, VarT ("numtype", []));
        (dummy_lbl, VarT ("num_", [ TypA (VarT ("numtype", [])) ]))
      ], []), []);
    ])
  ]);
```

**Maude:**
```maude
op CTORCONSTA2 : WasmTerminal WasmTerminal -> WasmTerminal [ctor] .
cmb ( CTORCONSTA2 ( NUMTYPE1 , NUM1 ) ) : Instr
   if type-check ( NUMTYPE1, numtype ) and type-check ( NUM1, num ( NUMTYPE1 ) ) .
```

---

#### VariantT - 패턴 2: 파라미터 타입 (`binop`)

**SpecTec:**
```
syntax binop_(Inn) = | ADD | SUB | ...
```

**IL:**
```ocaml
TypD ("binop_",
    [ TypP "numtype" ],
    [ InstD (
        [ ExpB ("Inn", VarT ("numtype", [])) ],
        [ TypA (VarT ("Inn", [])) ],
        VariantT [
          (["ADD"], ([], TupT [], []), []);
          (["SUB"], ([], TupT [], []), []);
        ]
    )]
  );
```

**Maude:**
```maude
op binop : WasmTerminal -> WasmType [ctor] .
op CTORADDA0 : -> WasmTerminal [ctor] .
ceq type-ok ( CTORADDA0 , binop ( INN ) ) = true if type-check ( INN , numtype ) .
op CTORSUBA0 : -> WasmTerminal [ctor] .
ceq type-ok ( CTORSUBA0 , binop ( INN ) ) = true if type-check ( INN , numtype ) .
```

(파라메트릭 타입이므로 membership 대신 `type-ok` Bool 연산자 사용.)

---

#### AliasT

**SpecTec:**
```
syntax idx = u32
```

**IL:**
```ocaml
TypD (id "idx", [], [InstD ([], [], AliasT (VarT (id "u32", [])))]);
```

**Maude:**
```maude
sort Idx .
subsort Idx < WasmType .
op idx : -> WasmType [ctor] .
mb ( T ) : Idx .
```

(`idx` 는 특별 케이스로 unconditional 멤버십 발행 — 모든 `WasmTerminal` 을 `Idx` 로 승격.)

---

#### StructT

**SpecTec:**
```
syntax memarg = {ALIGN u32, OFFSET u32}
```

**IL:**
```ocaml
TypD ("memarg", [], [
  InstD ([], [], StructT [
    ("ALIGN",  VarT ("u32", []));
    ("OFFSET", VarT ("u32", []))
  ])
])
```

**Maude:**
```maude
sort Memarg .
subsort Memarg < WasmType .
op memarg : -> WasmType [ctor] .
cmb ( { item('ALIGN, ( F-ALIGN-0 )) ; item('OFFSET, ( F-OFFSET-1 )) } ) : Memarg
   if type-check ( F-ALIGN-0, u32 ) and type-check ( F-OFFSET-1, u32 ) .
```

---

### A.2 def (DecD)

#### 단순 `eq` 없이 조건만 (`$const`)

**SpecTec:**
```
def $const(numtype, c : lit_(numtype)) : instr = (CONST numtype c)
```

**Maude:**
```maude
op $const : WasmTerminal WasmTerminal -> WasmTerminal .
vars CONST0-NUMTYPE CONST0-C : WasmTerminal .
ceq $const ( CONST0-NUMTYPE , CONST0-C ) = CTORCONSTA2 ( CONST0-NUMTYPE, CONST0-C )
   if type-check ( CONST0-NUMTYPE , numtype )
  and type-check ( CONST0-C , lit ( CONST0-NUMTYPE ) ) .
```

---

#### `ceq` (`$iadd`)

**SpecTec:**
```
def $iadd_(N, i_1 : iN(N), i_2 : iN(N)) : iN(N) = $((i_1 + i_2) \ 2^N)
```

**Maude:**
```maude
op $iadd : WasmTerminal WasmTerminal WasmTerminal -> WasmTerminal .
vars IADD0-N IADD0-I1 IADD0-I2 : WasmTerminal .
ceq $iadd ( IADD0-N , IADD0-I1 , IADD0-I2 )
   = ( ( IADD0-I1 + IADD0-I2 ) rem ( 2 ^ IADD0-N ) )
   if type-check ( IADD0-N , w-N )
  and type-check ( IADD0-I1 , iN ( IADD0-N ) )
  and type-check ( IADD0-I2 , iN ( IADD0-N ) ) .
```

(binder 의 접미사 `_1`, `_2` 는 `resolve_suffixed` 가 처리하여 `I1`, `I2` 로 매핑.)

---

#### `ceq` with dispatch (`$binop`)

**SpecTec:**
```
def $binop_(Inn, ADD, i_1 : iN($size(Inn)), i_2 : iN($size(Inn)))
  : iN($size(Inn))
  = $iadd_($size(Inn), i_1, i_2)
```

**Maude:**
```maude
ceq $binop ( BINOP0-INN , CTORADDA0 , BINOP0-I1 , BINOP0-I2 )
   = $iadd ( $size ( BINOP0-INN ) , BINOP0-I1 , BINOP0-I2 )
   if type-check ( BINOP0-INN , numtype )
  and type-check ( BINOP0-I1 , iN ( $size ( BINOP0-INN ) ) )
  and type-check ( BINOP0-I2 , iN ( $size ( BINOP0-INN ) ) ) .
```

---

### A.3 rule (RelD)

#### Step-pure, 전제 없음 (`Step_pure/nop`)

**SpecTec:**
```
rule Step_pure/nop: NOP ~> eps
```

**Maude:** (translate_step_reld → step 방정식)
```maude
vars STEP-PURE-NOP-Z : WasmTerminal .
var  STEP-PURE-NOP-IS : WasmTerminals .
eq step(< STEP-PURE-NOP-Z | CTORNOPA0 STEP-PURE-NOP-IS >)
   = < STEP-PURE-NOP-Z | STEP-PURE-NOP-IS > .
```

---

#### Step-pure, 전제 있음 (`Step_pure/binop-val`)

**SpecTec:**
```
rule Step_pure/binop-val:
  (CONST nt c_1) (CONST nt c_2) (BINOP nt binop)  ~>  (CONST nt c)
  -- if c <- $binop_(nt, binop, c_1, c_2)
```

**Maude:**
```maude
vars STEP-PURE-BINOP-VAL-Z          --- 결론 상태 변수
     STEP-PURE-BINOP-VALP-NT
     STEP-PURE-BINOP-VALP-C1
     STEP-PURE-BINOP-VALP-C2
     STEP-PURE-BINOP-VALP-BINOP
     STEP-PURE-BINOP-VALP-C : WasmTerminal .
var  STEP-PURE-BINOP-VAL-IS : WasmTerminals .

ceq step(< STEP-PURE-BINOP-VAL-Z |
           CTORCONSTA2(STEP-PURE-BINOP-VALP-NT, STEP-PURE-BINOP-VALP-C1)
           CTORCONSTA2(STEP-PURE-BINOP-VALP-NT, STEP-PURE-BINOP-VALP-C2)
           CTORBINOPA2(STEP-PURE-BINOP-VALP-NT, STEP-PURE-BINOP-VALP-BINOP)
           STEP-PURE-BINOP-VAL-IS >)
    = < STEP-PURE-BINOP-VAL-Z |
        CTORCONSTA2(STEP-PURE-BINOP-VALP-NT, STEP-PURE-BINOP-VALP-C)
        STEP-PURE-BINOP-VAL-IS >
    if STEP-PURE-BINOP-VALP-C := $binop(STEP-PURE-BINOP-VALP-NT,
                                         STEP-PURE-BINOP-VALP-BINOP,
                                         STEP-PURE-BINOP-VALP-C1,
                                         STEP-PURE-BINOP-VALP-C2) .
```

- `c_1 / c_2 / c` 는 접미사 숫자가 alpha (`1→Q, 2→R`) 로 변환되어 `VALP/VALR/VALS` 같은 형태가 될 수 있으나, 여기서는 단순화해서 표기.
- 전제의 `c <- $binop(...)` 는 `c` 가 LHS 에 등장하지 않는 미바인딩 변수임을 스케줄러가 감지 → `:=` 바인딩으로 자동 변환.

---

#### Step-read (`Step_read/local.get`)

**SpecTec:**
```
rule Step_read/local.get: z; (LOCAL.GET x)  ~>_read  val
  -- if val = $local(z, x)
```

**Maude:**
```maude
ceq step(< STEP-READ-LOCAL-GETR-Z | CTORLOCALGETA1(STEP-READ-LOCAL-GETR-X) STEP-READ-LOCAL-GET-IS >)
    = < STEP-READ-LOCAL-GETR-Z | STEP-READ-LOCAL-GETR-VAL STEP-READ-LOCAL-GET-IS >
    if STEP-READ-LOCAL-GETR-VAL := $local(STEP-READ-LOCAL-GETR-Z, STEP-READ-LOCAL-GETR-X) .
```

---

#### Step (state-changing, `Step/local.set`)

**SpecTec:**
```
rule Step/local.set: z; val (LOCAL.SET x)  ~>  z'; eps
  -- if z' = $with_local(z, x, val)
```

**Maude:** (translate_step_reld 가 번역하지만 `$with-local` 자동 구현이 부정확한 케이스 — `wasm-exec.maude` 에서 수작업 우회 중. 자세한 내용은 `architecture_decisions.md §B` 참조.)

```maude
--- 자동 생성 (참고용)
ceq step(< STEP-LOCAL-SET-Z | STEP-LOCAL-SETP-VAL CTORLOCALSETA1(STEP-LOCAL-SETP-X) STEP-LOCAL-SET-IS >)
    = < STEP-LOCAL-SET-ZP | STEP-LOCAL-SET-IS >
    if STEP-LOCAL-SET-ZP := $with-local(STEP-LOCAL-SET-Z, STEP-LOCAL-SETP-X, STEP-LOCAL-SETP-VAL) .

--- wasm-exec.maude 의 수작업 우회 (실제로 동작하는 코드)
ceq step(< CTORSEMICOLONA2(ST-ZS, ST-ZF) | ST-VAL CTORLOCALSETA1(ST-X) ST-IS >)
    = < CTORSEMICOLONA2(ST-ZS, ST-ZF [. 'LOCALS <- value('LOCALS, ST-ZF) [ST-X <- ST-VAL]]) | ST-IS >
    if is-val(ST-VAL) = true .
```

---

#### 일반 관계: Typing (`Typing_instr/nop`)

**SpecTec:**
```
relation Typing_instr: context |- instr : functype

rule Typing_instr/nop: C |- NOP : (eps -> eps)
```

**Maude:** (translate_reld → Bool ceq)
```maude
op Typing-instr : WasmTerminal WasmTerminal WasmTerminal -> Bool .
vars TYPING-INSTR-NOP-C : WasmTerminal .
eq Typing-instr ( TYPING-INSTR-NOP-C , CTORNOPA0 , CTORARROWA2 ( eps , eps ) ) = true .
```

---

## Appendix B : 현재 커버리지 (2026-04-17 기준)

### B.1 입력

| 카테고리 | 파일 | 정의 수 |
|---|---|---|
| `syntax` | 21개 `.spectec` 파일 전체 | 249개 |
| `def`    | "" | ~1,200 clause |
| `relation` + `rule` | "" | 82 관계, 501 규칙 |

### B.2 번역 결과

| 항목 | 수량 |
|---|---|
| `output.maude` 총 줄 수 | 7,065 |
| `op` 선언 | 1,009 |
| `eq` 방정식 | 749 |
| `ceq` 방정식 | 618 |
| `sort` 선언 | 152 |
| `subsort` 선언 | 155 |
| `var` / `vars` 선언 | 202 / 395 |
| 자동 생성 `step` 방정식 (`translate_step_reld`) | 189 |
| 스킵된 규칙 (RulePr 브리지/컨텍스트) | ~312 |

### B.3 검증

- **등식 실행**: `steps(fib-config(i32v(5)))` → 5,949 rewrites → 결과 `CTORCONSTA2(CTORI32A0, 5)` ✓
- **LTL**: `<> result-is(5)` = `true`, `[] ~ trap-seen` = `true` ✓
- **Maude 로딩**: benign kind-level membership 경고만 발생, 실행 에러 없음.

### B.4 알려진 한계

1. `$with-local` (translate_decd 결과) 가 frame 의 `'LOCALS` 필드 갱신을 정확히 표현하지 못함 → `wasm-exec.maude` 에서 수작업 우회.
2. Memory load/store, table, call / call_ref / call_indirect, GC (struct/array), Exception (try/catch/throw), SIMD, atomic — step 방정식은 생성되지만 실행 검증 0건.
3. Validation/Typing relation 은 Bool 연산자로 번역되나 테스트 suite 부재.
4. `NegPr`(부정 전제) 는 현재 `translate_prem` 이 트랜스페어런트로 처리 — 조건 절에 부정이 반영되지 않음.
