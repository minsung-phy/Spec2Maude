# Spec2Maude Translator Mapping Specification

<div align="right">
  <strong>포항공과대학교 SVLab 이민성</strong><br>
  <strong>2026.03.06</strong>
</div>

## 1. Pipeline
본 문서는 WebAssembly SpecTec의 문법을 읽어, 실행 가능한 Maude Algebraic Specification으로 Mapping 알고리즘을 설명한다.

```text
.spectec 
-> [Spec2Maude Translator]
.maude
```


## 2. Pre-defined Infrastructure
변환된 코드가 의존하는 Maude 기반 환경과, 변환기 전체에서 공유되는 식별자 처리 규칙이다.

```text
(* Sorts *)
sort WasmTerminal .  *** 원자값, 생성자, 단일 명령어
sort WasmTerminals . *** 구문들의 리스트 (e.g., instr*)
sort WasmType .      *** 타입 카테고리 식별자

(* Core interface *)
op typecheck : WasmTerminal WasmType -> Bool .
op typecheck : WasmTerminals WasmType -> Bool .

(* Naming Conventions *)
sanitize(name)   (* '_' → '-',  trailing '%' 제거 *)
uppercase(name)  (* binder → Maude variable  e.g. inn → INN *)
is_plural(type)  (* AST 순회 중 리스트(*, +) 기호나 의미론적 복수형(expr) 식별 *)
```


## 3. translate_syntax
SpecTec의 syntax 구문을 Maude의 Sort 선언 및 typecheck 등식으로 변환한다. 분기 기준은 `|` (파이프)로 구분되는 하위 구조의 형태와 제약 조건 유무이다.

```text
Algorithm: Translate_Syntax
Input: "syntax T(b1...bn) = Body"

// 1. 공통 환경 (Environment & Target)
Let LHS = T(B1, ..., Bn)  // B_i는 b_i를 대문자화한 변수
Let Φ_binder = ⋀ typecheck(B_i, type_of(b_i))

// 2. 본문(Body) 구조 패턴 매칭
Match Body with:

	| inner_type ->  (* Alias Delegation *)
	    emit "eq typecheck(V, LHS) = Φ_binder /\ typecheck(V, inner_type) ."
	
	| C t1 ... tk ->  (* Constructor Rules *)
	    For each constructor case:
	        If k = 0:  // Constant (e.g., | NULL)
	            emit "op C : -> WasmTerminal [ctor] ."
	            emit "eq typecheck(C, LHS) = Φ_binder ."
	        
	        Else:      // Parameterized (e.g., | DIV sx)
                Let S_j = if is_plural(t_j) then "WasmTerminals" else "WasmTerminal"
	            Let Φ_args = ⋀ typecheck(V_j, t_j)  // V_j는 선형화된 고유 변수

	            emit "op C _..._ : (S_1 ... S_k) -> WasmTerminal [ctor] ."
	            emit "eq typecheck(C(V1...Vk), LHS) = Φ_binder /\ Φ_args ."
	            
	            If t1 is Optional (t*?):  // eps 기저 사례
	                emit "eq typecheck(C eps, LHS) = Φ_binder ."
	
	| 0 | ... | expr ->  (* Numerical Range Constraint *)
	    emit "ceq typecheck(i, LHS) = true if Φ_binder /\ evaluate(i, expr) ."
```


## 4. translate_DecD
SpecTec의 `def` 구문을 Maude `op` 선언과 패턴 매칭 기반 `eq` 절로 변환한다. 분기 기준은 좌항(LHS) 인자가 변수인지 생성자인지 여부이다.

```text
Algorithm: Translate_Def
Input: SpecTec 함수 정의 블록 (시그니처 1줄 + 세부 방정식 N줄)
  [Signature] "def $fname(p1...pn) : ret_type"
  [Equations] "def $fname(args) = rhs_expr"

// 1. 함수 이름 추출 및 시그니처 추상화 (op 선언)
Let f_name = extract_func_name(Signature)  // 예: $size
Let k = length(p1...pn)
emit "op {f_name} : WasmTerminal^k -> WasmTerminal ."

// 2. 바인더 변수 선언 및 환경(Environment) 구축
Let v_map = { p -> uppercase(p) | p ∈ p1...pn }
For each V in v_map.values:
    emit "var {V} : WasmTerminal ."

// 3. 개별 방정식(Equation) 리라이팅 규칙 도출
For each "def $fname(args) = rhs_expr" in Equations:
    
    // 우항 수식과 좌항 인자를 Maude 항으로 사전 변환
    Let RHS_term = translate_exp(rhs_expr, v_map)
    Let arg_str  = translate_exp(args, v_map)
    
    Match args with:
    
    | [] ->  (* 기저 사례: 인자가 없는 경우 *)
        emit "eq {f_name} = {RHS_term} ."
        
    | [Variable(x), ...] ->  (* 일반 사례: 변수 패턴 (예: x) *)
        emit "var {arg_str} : WasmTerminal ."
        emit "eq {f_name}({arg_str}) = {RHS_term} ."
        
    | [Constructor(C), ...] ->  (* 일반 사례: 생성자 패턴 (예: I32) *)
        emit "eq {f_name}({arg_str}) = {RHS_term} ."
```


## 5. Summary

전체 변환 규칙을 케이스별로 정리한다. `*`는 일반 규칙과 분리된 Special Case이다.

| Rule | SpecTec Condition | Maude Output Pattern |
| :--- | :--- | :--- |
| **Syntax-Const** | `\| C` (제약 및 인자 없음) | `eq typecheck(C, LHS) = Φ_binder .` |
| **Syntax-Cons** | `\| C t1 ... tk` (제약 없음, 인자 있음) | `eq typecheck(C(V1...Vk), LHS) = Φ_binder /\ Φ_args .` |
| **Syntax-Alias** | `syntax T = inner` | `eq typecheck(V, LHS) = Φ_binder /\ typecheck(V, inner) .` |
| **\* Numerical Range** | `\| 0 \| ... \| expr` | `ceq typecheck(i, LHS) = true if Φ_binder /\ evaluate(i, expr) .` |
| **\* Optional / eps** | 인자 중 `t*?` 존재 시 | `eq typecheck(C eps, LHS) = true .` |
| **Def-General** | `def $f(x) = rhs`<br>(또는 인자 없는 경우) | `op $f : WasmTerminal^k -> WasmTerminal .`<br>`eq $f(X) = translate_exp(rhs) .` |
| **Def-Cons** | `def $f(C) = rhs` | `eq $f(C) = translate_exp(rhs) .` |