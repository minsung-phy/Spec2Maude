# Spec2Maude 변환 규칙 일람표 (Cheat Sheet)

> 포항공과대학교 SVLab · 2026.03.17

---

## 1. Top-Level Definition (`def'`) Dispatch

| AST 노드 (SpecTec) | 내부 구조 (OCaml) | 변환 규칙 | Maude 출력 예시 |
|---|---|---|---|
| `syntax X = A \| B` | `TypD → VariantT(cases)` | 각 case별 `op`+`eq typecheck(...)` 생성 | `op BLOCK _ _ : ... [ctor] .` |
| `syntax X = Y` | `TypD → AliasT(τ)` | `eq typecheck(V, X) = typecheck(V, Y)` | `eq typecheck(TS, expr) = typecheck(TS, instr) .` |
| `syntax X = {F₁, F₂}` | `TypD → StructT(fields)` | `eq typecheck({item('F₁,V₁);...}, X)` | `eq typecheck({item('TYPE,V);item('REFS,W)}, tableinst) = ...` |
| `def $f(x) = e` | `DecD → DefD(b,a,e,p)` | `op $f : S → S .` + `eq/ceq` | `ceq $growtable(...) = ... if ... .` |
| `relation R: ...` | `RelD(id,mixop,τ,rules)` | `op R : ... → Bool .` | `op Instr-ok : WasmTerminal → Bool .` |
| `rule R/case: ...` | `RuleD(id,b,m,e,p)` | `ceq R(conclusion) = true if premises` | `ceq Instr-ok((C, BLOCK, ...)) = true if ... .` |
| `rec { d₁; d₂ }` | `RecD(defs)` | 재귀적으로 각 def 순회 | (투명 래퍼) |
| `grammar ...` | `GramD` | Skip (binary/text 범위 밖) | — |
| `hint(...)` | `HintD` | Skip (메타데이터) | — |

---

## 2. VariantT Case 처리 세부 규칙

| 패턴 | 조건 | 변환 규칙 | Maude 출력 예시 |
|---|---|---|---|
| 일반 생성자 | `prems = ∅` | `op C _ : S → WT [ctor] .` + `eq typecheck(C V, T) = ...` | `op BLOCK _ _ : WasmTerminal WasmTerminal → WasmTerminal [ctor] .` |
| 조건부 생성자 | `prems ≠ ∅` | `ceq typecheck(i, T) = true if conds` | `ceq typecheck(i, uN) = true if (N <= (2^N - 1)) .` |
| 빈 생성자 | `mixop atoms = ∅` | `op` 생략, `eq typecheck(V₁ V₂, T)` | `eq typecheck(RESULTTYPE1 RESULTTYPE2, functype) = ...` |
| Mixfix 생성자 | atoms 중간 배치 | `interleave_lhs(sections, vars)` | `eq typecheck(V₁ arrow- V₂ V₃, instrtype) = ...` |
| Opt 인자 eps | `IterT(_, Opt)` 탐지 | 해당 인자만 `eps`로 치환한 추가 eq | `eq typecheck(-RESULT eps, blocktype) = true .` |

---

## 3. Expression (`exp'`) 변환 — 32개 분기

| AST 노드 | OCaml 타입 | 변환 규칙 | Maude 출력 예시 |
|---|---|---|---|
| `VarE(id)` | 변수 참조 | `Γ(id)` or `UPPER(id)` | `BLOCK_C` |
| `NumE(n)` | 수 리터럴 | `to_string(n)` | `32` |
| `BoolE(b)` | 불리언 | `"true"` / `"false"` | `true` |
| `TextE(s)` | 문자열 | `"\"s\""` | `"hello"` |
| `CaseE(mixop, e)` | 생성자 적용 | head atom name or strip | `BLOCK` |
| `UnE(op, _, e)` | 단항 연산 | `op(e)` | `not (X)` |
| `BinE(op, _, e₁, e₂)` | 이항 연산 | `(e₁ op e₂)` | `(A + B)` |
| `CmpE(op, _, e₁, e₂)` | 비교 연산 | `(e₁ op e₂)` | `(X == Y)` |
| `CallE(id, args)` | 함수 호출 | `$f(args)` | `$sizenn(INN)` |
| `TupE(es)` | 튜플 | `(e₁, e₂, ...)` | `(A, B)` |
| `ListE(es)` | 리스트 | `e₁ e₂ ...` (juxtaposition) | `I32 I64` |
| `CatE(e₁, e₂)` | 리스트 연결 | `e₁ e₂` | `FREE_FREE FREE'` |
| `LenE(e)` | 길이 | `len(e)` | `len(R')` |
| `IdxE(e₁, e₂)` | 인덱싱 | `index(e₁, e₂)` | `index(SUBTYPE, I)` |
| `SliceE(e, i, j)` | 슬라이스 | `slice(e, i, j)` | `slice(B, I, J)` |
| `StrE(fields)` | 레코드 리터럴 | `{item('F, e); ...}` | `{item('TYPES, V) ; item('FUNCS, W)}` |
| `DotE(e, atom)` | 레코드 접근 | `value('F, e)` | `value('LABELS, C)` |
| `CompE(e₁, e₂)` | 레코드 합성 | `e₁ ++ e₂` | `$free_a(...) ++ $free_b(...)` |
| `MemE(e₁, e₂)` | 멤버십 | `(e₁ <- e₂)` | `(W <- W')` |
| `UpdE(e, path, v)` | 상태 갱신 | `e[path <- v]` | `S[.'GLOBALS[X] <- V]` |
| `ExtE(e, path, v)` | 상태 확장 | `e[path =++ v]` | `S[.'STRUCTS =++ SI]` |
| `OptE(Some e)` | 옵셔널 존재 | `e` (unwrap) | `VALTYPE` |
| `OptE(None)` | 옵셔널 부재 | `eps` | `eps` |
| `TheE(e)` | `e!` 언래핑 | `e` (unwrap) | `DT` |
| `IterE(e, _)` | 반복 | `e` (strip wrapper) | `INSTR` |
| `IfE(c, e₁, e₂)` | 조건식 | `if c then e₁ else e₂ fi` | `if X then A else B fi` |
| `LiftE(e)` | 코어션 | `e` (strip) | `T` |
| `CvtE(e, _, _)` | 타입 변환 | `e` (strip) | `N` |
| `SubE(e, _, _)` | 부분타입 | `e` (strip) | `T` |
| `ProjE(e, _)` | 투영 | `e` (strip) | `RT` |
| `UncaseE(e, _)` | 언케이스 | `e` (strip) | `V` |

---

## 4. Premise (`prem'`) 변환 — 6개 분기

| AST 노드 | OCaml 타입 | 변환 규칙 | Maude 출력 예시 |
|---|---|---|---|
| `IfPr(e)` | 조건 전제 | `translate_exp(e)` | `(SZ < $sizenn(INN))` |
| `RulePr(id, _, e)` | 관계 전제 | `R(translate_exp(e))` | `Valtype-ok((C, T))` |
| `LetPr(e₁, e₂, _)` | 바인딩 | `(e₁ := e₂)` | `(DT := $expanddt(X))` |
| `ElsePr` | otherwise | `[owise]` 속성 | `. [owise]` |
| `IterPr(p, _)` | 반복 전제 | 재귀 strip | (투명 래퍼) |
| `NegPr(p)` | 부정 전제 | `not(translate_prem(p))` | `not(Defaultable(...))` |

---

## 5. Type (`typ'`) 변환

| AST 노드 | 변환 규칙 | Maude 출력 예시 |
|---|---|---|
| `VarT(id, [])` | `Γ(id)` or `sanitize(id)` | `valtype` |
| `VarT(id, args)` | `id(args)` | `num-(INN)` |
| `BoolT` | `"Bool"` | `Bool` |
| `NumT(_)` | `"Nat"` | `Nat` |
| `TextT` | `"text"` | `text` |
| `TupT(fields)` | 재귀 순회 | `valtype valtype` |
| `IterT(inner, _)` | strip, inner 번역 | `instr` |

---

## 6. Path (`path'`) 변환 (UpdE/ExtE 용)

| AST 노드 | 변환 규칙 | Maude 출력 예시 |
|---|---|---|
| `RootP` | `""` | (empty) |
| `DotP(p, atom)` | `p.'FIELD` | `.'GLOBALS` |
| `IdxP(p, e)` | `p[e]` | `.'TABLES[X]` |
| `SliceP(p, e₁, e₂)` | `p[e₁ : e₂]` | `.'BYTES[I : J]` |

---

## 7. 구조적 헬퍼 함수 요약

| 함수명 | 용도 | 하드코딩 대체 |
|---|---|---|
| `build_type_env` | AliasT(IterT(_, List)) 구조 사전 스캔 | `is_plural_type("expr")` 제거 |
| `mixop_sections` | mixop atom 리스트를 섹션별 문자열로 분해 | — |
| `interleave_lhs` | 섹션과 변수를 교차 배치 (LHS 포맷) | `if name="->-"` 제거 |
| `interleave_op` | 섹션과 `_` 슬롯 교차 배치 (op 선언) | `"_ ->- _ _"` 제거 |
| `find_opt_param_indices` | 타입 구조에서 Opt 위치 인덱스 탐색 | `List.length params = 1` 제거 |
| `translate_path` | UpdE/ExtE 경로 재귀 번역 | (신규) |
| `translate_prem` | 전제조건 6종 패턴 매칭 | `IfPr`만 처리하던 한계 제거 |
