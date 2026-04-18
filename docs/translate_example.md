# Spec2Maude 대표 변환 예시

- **syntax**: hasType / WellTyped 사용 예 포함
- **def**: 일반 함수 정의 
- **rule**: 4 패턴
  - Pattern 1 (일반 RelD 판정) — `cmb : ValidJudgement` 
  - Pattern 2-4 (Step-pure / Step-read / Step) — **`rl`/`crl` 형태**

IL AST 형태는 [lib/il/ast.ml](lib/il/ast.ml) 의 생성자 기준으로 축약하여 표기한다.

---

## 1. Syntax 변환

### 예시 A. Variant syntax + hasType / WellTyped

파라미터 N 을 받는 variant 타입. 각 case 에 조건 프리미스가 붙을 수 있다.
조건이 없는 case는 `mb`, 조건 있는 case는 `cmb` 로 내려간다.

#### SpecTec
출처: [wasm-3.0/1.1-syntax.values.spectec#L51](wasm-3.0/1.1-syntax.values.spectec#L51)

```text
syntax fNmag(N) hint(desc "floating-point magnitude") =
  | NORM m exp   -- if $(m < 2^$M(N) /\ 2-2^($E(N)-1) <= exp <= 2^($E(N)-1)-1)
  | SUBNORM m    -- if $(m < 2^$M(N) /\ 2-2^($E(N)-1) = exp)
  | INF
  | NAN (m)      -- if $(1 <= m < 2^$M(N))
```

#### IL AST (축약)
관련 생성자: [TypD](lib/il/ast.ml#L138), [InstD](lib/il/ast.ml#L147), [VariantT](lib/il/ast.ml#L41), [typcase](lib/il/ast.ml#L44), [IfPr](lib/il/ast.ml#L164)

```ocaml
TypD ("fNmag",
  [ ExpP ("N", NumT NatT) ],
  [ InstD ([], [ExpA (VarE "N")],
      VariantT [
        (mixop "NORM",    ([...], ..., [IfPr (...)]), []);
        (mixop "SUBNORM", ([...], ..., [IfPr (...)]), []);
        (mixop "INF",     ([],    ...,        []),   []);
        (mixop "NAN",     ([...], ..., [IfPr (...)]), []);
      ])
  ])
```

#### output.maude

```maude
  cmb ( CTORNORMA2 ( M1, EXP1 ) hasType ( fNmag ( N ) ) ) : WellTyped
    if ( ( M1 < ( 2 ^ $M ( N ) ) )
       and ( ( 2 - ( 2 ^ ( $E ( N ) - 1 ) ) ) <= EXP1
             and EXP1 <= ( ( 2 ^ ( $E ( N ) - 1 ) ) - 1 ) ) ) = true .

  cmb ( CTORSUBNORMA1 ( M1 ) hasType ( fNmag ( N ) ) ) : WellTyped
    if ( ( M1 < ( 2 ^ $M ( N ) ) )
       and ( ( 2 - ( 2 ^ ( $E ( N ) - 1 ) ) ) == EXP ) ) = true .

  mb ( CTORINFA0 hasType ( fNmag ( N ) ) ) : WellTyped .

  cmb ( CTORNANA1 ( M1 ) hasType ( fNmag ( N ) ) ) : WellTyped
    if ( ( 1 <= M1 ) and ( M1 < ( 2 ^ $M ( N ) ) ) ) = true .
```

#### 설명 포인트
- 파라미터 있는 variant → `hasType ( fNmag ( N ) ) : WellTyped` 멤버십.
- 조건 IfPr → `cmb ... if ...` 의 가드.
- 조건 없는 case (INF) → `mb` (무조건 membership).
- **이 패턴은 상태 전이가 아님 — mb/cmb 가 정답. 현재 구조 유지.**

---

## 2. Def 변환

### 예시 B. 함수 정의 (DecD + 여러 DefD 절) — 현재 방식 OK

#### SpecTec
출처: [wasm-3.0/1.1-syntax.values.spectec#L32](wasm-3.0/1.1-syntax.values.spectec#L32)

```text
def $signif(N) : nat hint(partial)
def $signif(32) = 23
def $signif(64) = 52
```

#### IL AST (축약)
관련 생성자: [DecD](lib/il/ast.ml#L140), [DefD](lib/il/ast.ml#L155)

```ocaml
DecD ("$signif",
  [ ExpP ("N", NumT NatT) ],
  NumT NatT,
  [
    DefD ([], [ExpA (NumE 32)], NumE 23, []);
    DefD ([], [ExpA (NumE 64)], NumE 52, []);
  ])
```

#### output.maude (목표 = 현재와 동일)

```maude
  eq $signif ( 32 ) = 23 .
  eq $signif ( 64 ) = 52 .
```

#### 설명 포인트
- DefD 절 → 하나의 `eq` (조건 있으면 `ceq`).
- **상태 전이가 아닌 순수 함수 정의** — eq 가 정답.

---

## 3. Rule 변환 (4 패턴)

SpecTec 의 `rule R: ...` 은 소속 relation 에 따라 4가지로 갈린다. **Pattern 1 만 membership (cmb), 나머지 3 개는 전부 rl/crl (rewriting rule) + step 래퍼** 로 내려야 한다.

| 패턴 | 상태 전이? | 목표 형태 |
|------|-----------|-----------|
| 1. 일반 RelD 판정 | ❌ (타입 판정) | `cmb ... : ValidJudgement` |
| 2. Step-pure | ✅ (instr 재작성) | `rl step(< Z \| ... >) => step(< Z \| ... >)` |
| 3. Step-read | ✅ (상태 읽기만) | `crl step(< Z \| ... >) => step(< Z \| ... >) if ...` |
| 4. Step | ✅ (상태 변화) | `crl step(< Z \| ... >) => step(< Z' \| ... >) if ...` |

---

### 패턴 1. 일반 RelD 판정 규칙 — 현재 방식 OK

#### SpecTec
출처: [wasm-3.0/2.1-validation.types.spectec#L14](wasm-3.0/2.1-validation.types.spectec#L14)

```text
relation Numtype_ok: context |- numtype : OK

rule Numtype_ok:
  C |- numtype : OK
```

#### IL AST (축약)
관련 생성자: [RelD](lib/il/ast.ml#L139), [RuleD](lib/il/ast.ml#L151)

```ocaml
RelD ("Numtype_ok",
  mixop "|- _ : OK",
  TupT [ctx_typ; numtype_typ],
  [
    RuleD ("Numtype_ok",
      [ExpB ("C", ctx_typ); ExpB ("numtype", numtype_typ)],
      mixop "|- _ : OK",
      TupE [ VarE "C"; VarE "numtype" ],
      [])
  ])
```

#### output.maude (목표 = 현재와 동일)

```maude
  cmb Numtype-ok ( C , NUMTYPE ) : ValidJudgement
    if C : Context /\ NUMTYPE : Numtype .
```

#### 설명 포인트
- 판정 (validation) 은 **상태 전이 아님** → `cmb : ValidJudgement` 로 내리는 것이 맞음.
- Binder 의 타입은 LHS 조건으로 남는다.

---

### 패턴 2. Step-pure 규칙 — ⚠ 재설계 필요

상태 Z 변화 없음 + 프리미스 없음 → **`rl` (unconditional rewriting rule) + step 래퍼**.

#### SpecTec
출처: [wasm-3.0/4.3-execution.instructions.spectec#L55](wasm-3.0/4.3-execution.instructions.spectec#L55)

```text
rule Step_pure/nop:
  NOP  ~>  eps
```

#### IL AST (축약)
관련 생성자: [RuleD](lib/il/ast.ml#L151), [CaseE](lib/il/ast.ml#L64), [VarE](lib/il/ast.ml#L55)

```ocaml
RuleD ("Step_pure/nop",
  [],
  mixop "_ ~> _",
  TupE [
    CaseE (mixop "NOP", TupE []);
    VarE "eps";
  ],
  [])
```

#### ❌ 현재 output.maude (틀림 — eq 는 교수님 원칙 §2.2 위반)

```maude
  eq step(< Z | CTORNOPA0 IS >) = < Z | eps IS > .
```

#### ✅ 목표 output.maude (rl 로 재설계)

```maude
  rl [step-pure-nop] :
    step(< Z | CTORNOPA0 IS >)
    => step(< Z | eps IS >) .
```

#### 설명 포인트
- `step(...)` 래퍼가 LHS 에 있음 → step 이 감싸져 있을 때만 매칭 → 임의 서브텀 매칭 차단 (프로즌 대체).
- RHS 에도 `step(...)` 유지 → 다음 스텝을 이어서 갈 수 있음 (model checking 에서 연속 rewrite 가능).
- 프리미스 없음 → `rl` (unconditional).
- `[step-pure-nop]` 같은 라벨은 trace/debug 용 (선택).
- **1 rewrite = 정확히 1 step** — 교수님 원칙 §2.4 정합.

---

### 패턴 3. Step-read 규칙 — ⚠ 재설계 필요

상태 Z 를 읽기만 하고 변경하지 않음. 프리미스로 Z 의 값을 조회. → **`crl` (conditional rewriting rule) + step 래퍼**.

#### SpecTec
출처: [wasm-3.0/4.3-execution.instructions.spectec#L345](wasm-3.0/4.3-execution.instructions.spectec#L345)

```text
rule Step_read/table.size:
  z; (TABLE.SIZE x)  ~>  (CONST at n)
  -- if |$table(z, x).REFS| = n
  -- if $table(z, x).TYPE = at lim rt
```

#### IL AST (축약)
관련 생성자: [RuleD](lib/il/ast.ml#L151), [IfPr](lib/il/ast.ml#L164), [CallE](lib/il/ast.ml#L80), [DotE](lib/il/ast.ml#L69), [LenE](lib/il/ast.ml#L74)

```ocaml
RuleD ("Step_read/table.size",
  [ExpB ("z", ...); ExpB ("x", ...); ExpB ("at", ...); ExpB ("n", ...)],
  mixop "_; _ ~> _",
  TupE [
    VarE "z";
    CaseE (mixop "TABLE.SIZE", VarE "x");
    CaseE (mixop "CONST", TupE [VarE "at"; VarE "n"]);
  ],
  [
    IfPr (CmpE (EqOp, _,
            LenE (DotE (CallE ("$table", [VarE "z"; VarE "x"]), atom "REFS")),
            VarE "n"));
    IfPr (CmpE (EqOp, _,
            DotE (CallE ("$table", [VarE "z"; VarE "x"]), atom "TYPE"),
            TupE [VarE "at"; VarE "lim"; VarE "rt"]));
  ])
```

#### ❌ 현재 output.maude (틀림)

```maude
  ceq step(< Z | VALS CTORTABLESIZEA1 ( X ) IS >)
    = < Z | VALS CTORCONSTA2 ( AT, N ) IS >
    if (len(value('REFS, $table(Z, X))) == N) = true
    /\ (value('TYPE, $table(Z, X)) == AT LIM RT) = true
    /\ all-vals(VALS) = true .
```

#### ✅ 목표 output.maude (crl 로 재설계)

```maude
  crl [step-read-table-size] :
    step(< Z | VALS CTORTABLESIZEA1 ( X ) IS >)
    => step(< Z | VALS CTORCONSTA2 ( AT, N ) IS >)
    if (len(value('REFS, $table(Z, X))) == N) = true
    /\ (value('TYPE, $table(Z, X)) == AT LIM RT) = true
    /\ all-vals(VALS) = true .
```

#### 설명 포인트
- 좌/우 상태 Z 동일 (Z → Z) → 읽기 전용.
- IfPr 2 개 → `crl ... if` 가드 2 개.
- `all-vals ( VALS ) = true` → 스택 앞부분이 값 뿐 보장 (§2.3 context 분해).
- **변환 핵심: `ceq` → `crl`, `=` → `=>`, RHS 에 `step(...)` 유지.**

---

### 패턴 4. Step 규칙 — ⚠ 재설계 필요

상태 Z 가 Z' 로 바뀜. 값 꺼내 지역 변수에 쓰는 LOCAL.SET 이 전형. → **`crl` + step 래퍼 + 상태 교체**.

#### SpecTec
출처: [wasm-3.0/4.3-execution.instructions.spectec#L309](wasm-3.0/4.3-execution.instructions.spectec#L309)

```text
rule Step/local.set:
  z; val (LOCAL.SET x)  ~>  $with_local(z, x, val); eps
```

#### IL AST (축약)
관련 생성자: [RuleD](lib/il/ast.ml#L151), [CallE](lib/il/ast.ml#L80), [CaseE](lib/il/ast.ml#L64)

```ocaml
RuleD ("Step/local.set",
  [ExpB ("z", ...); ExpB ("val", ...); ExpB ("x", ...)],
  mixop "_; _ ~> _",
  TupE [
    VarE "z";
    ListE [ VarE "val"; CaseE (mixop "LOCAL.SET", VarE "x") ];
    TupE [
      CallE ("$with_local", [VarE "z"; VarE "x"; VarE "val"]);
      VarE "eps"
    ]
  ],
  [])
```

#### ❌ 현재 output.maude (틀림)

```maude
  ceq step(< Z | VALS VAL CTORLOCALSETA1 ( X ) IS >)
    = < $with-local ( Z, X, VAL ) | VALS eps IS >
    if is-val ( VAL ) = true
    /\ all-vals ( VALS ) = true .
```

#### ✅ 목표 output.maude (crl 로 재설계)

```maude
  crl [step-local-set] :
    step(< Z | VALS VAL CTORLOCALSETA1 ( X ) IS >)
    => step(< $with-local ( Z, X, VAL ) | VALS eps IS >)
    if is-val ( VAL ) = true
    /\ all-vals ( VALS ) = true .
```

#### 설명 포인트
- 왼쪽 Z → 오른쪽 `$with-local(Z, X, VAL)` — **상태 교체**.
- `is-val(VAL) = true` → LHS 의 `val` 이 진짜 값인지 확인.
- `all-vals(VALS) = true` → 앞쪽 스택 값만 보장.
- step 래퍼가 양쪽에 유지 → 다음 스텝으로 체인.
- **이 형태가 SpecTec 의 top-most 1-step 의미를 Maude 의 rewriting rule 로 올바르게 보존하는 형태** (§2.1, §2.4).

---

## 4. 요약 표 (랩미팅 30초용)

| SpecTec 구성요소 | IL AST 생성자 | 목표 Maude 형태 | 현재 상태 |
|------------------|---------------|------------------|-----------|
| syntax (variant + 조건) | TypD / VariantT / IfPr | `(c)mb ... hasType (τ) : WellTyped` | ✅ OK |
| syntax (단순 alias/sort) | TypD / AliasT | `sort X . subsort X < Y .` | ✅ OK |
| def (함수) | DecD / DefD | `(c)eq f(args) = body .` | ✅ OK |
| RelD 판정 rule | RelD / RuleD (일반) | `cmb J(args) : ValidJudgement if ...` | ✅ OK |
| rule Step_pure | RuleD in RelD "Step_pure" | `rl step(< Z \| instr IS >) => step(...)` | ⚠ 현재 `eq` (틀림) |
| rule Step_read | RuleD in RelD "Step_read" + IfPr | `crl step(< Z \| ... >) => step(< Z \| ... >) if ...` | ⚠ 현재 `ceq` (틀림) |
| rule Step | RuleD in RelD "Step" | `crl step(< Z \| ... >) => step(< Z' \| ... >) if ...` | ⚠ 현재 `ceq` (틀림) |

**핵심 구분선**:
- **상태 전이가 아닌 것** (syntax, def, 판정) → `eq` / `mb` / `cmb`
- **상태 전이인 것** (Step/Step-pure/Step-read) → `rl` / `crl` + `step(...)` 래퍼

---

## 5. 랩미팅 발표용 메시지

### 5.1 보여줄 것 (성과)
- Syntax (hasType 포함) / Def / 일반 판정 RelD 의 변환 패턴은 확립되었고, 교수님 요구에 부합.
- 4 가지 Rule 패턴 분류 자체는 끝남.

### 5.2 고백할 것 (문제)
- 현재 Step / Step-pure / Step-read 변환이 `eq`/`ceq` 로 나가고 있음 → 0331 미팅 원칙 위반임을 인지함.
- 재설계 방향: `rl`/`crl` + `step(...)` 래퍼.
- 이와 별개로 V128 membership 재귀로 인한 step() stack overflow 도 미해결 (P0-B) — 단, P0-0 해결 순서가 선.

### 5.3 요청할 것 (확인)
- `step(...)` 래퍼의 유지 정책: RHS 에 `step(...)` 을 남겨 연쇄 rewrite 가능하게 할 것인가 (propagating), 아니면 1 rewrite 후 래퍼가 빠져 외부 루프가 다시 감싸는 방식 (one-shot) 인가?
- ex.md 의 예시는 **propagating** 을 가정했음 — 교수님 의도와 맞는지 확인 필요.

---

## 6. 참고 문서

- [CLAUDE.md](CLAUDE.md) — 프로젝트 가이드 + 교수님 요구사항 §2.2 (eq/rl 구분)
- [STATUS.md](STATUS.md) — 현재 상태 / P0-0 (이 문제의 해결 플랜)
- [labmeeting.md](labmeeting.md) — 4 패턴 기존 문서 (현재 eq/ceq 표기 — 재작성 필요)
- [docs/logic/project_goals_and_prof_requirements.md](docs/logic/project_goals_and_prof_requirements.md) — 요구사항 원본
- [meeting/0331 개인.txt](meeting/0331%20개인.txt) — 본 재설계의 직접 근거 (24:03 / 24:55 / 27:04)
- [lib/il/ast.ml](lib/il/ast.ml) — IL AST 정의
- [translator.ml](translator.ml) — 번역기 구현 (재설계 대상)
