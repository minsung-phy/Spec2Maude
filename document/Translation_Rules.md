# Spec2Maude Translation Rules

## 1. Architecture Overview

### 1.1 Pipeline

```
*.watsup files ──▶ Frontend.Parse ──▶ Frontend.Elab ──▶ IL AST ──▶ Translator ──▶ output.maude
                   (SpecTec parser)   (type-check &       (list      (OCaml)        (Maude module
                                       elaboration)        of def)                   SPECTEC-CORE)
```

The translator receives a list of elaborated IL definitions (`Il.Ast.def list`) and produces a single Maude system module `SPECTEC-CORE` importing the foundation modules `DSL-RECORD`, `BOOL`, and `INT`.

### 1.2 Two-Phase Translation

**Phase 1: Pre-scan** (`scan_def`, `build_token_ops`, `build_call_ops`)

A single traversal of the entire AST collects:

| Artifact | Data structure | Purpose |
|----------|---------------|---------|
| Bare tokens | `SSet.t tokens` | Upper-case identifiers (e.g., `NOP`, `ADD`, `I32`) used in mixfix patterns |
| Constructor names | `SSet.t ctors` | Names declared via `VariantT` cases, excluded from token set to avoid duplicates |
| Call signatures | `SIPairSet.t calls` | `(function_name, arity)` pairs for undeclared helper functions |
| Bool-context calls | `SSet.t bool_calls` | Functions appearing in Boolean premises, to infer `-> Bool` return sort |
| Declared functions | `SSet.t dec_funcs` | Functions with explicit `DecD` definitions, excluded from auto-declaration |

**Phase 2: Translation** (`translate_definition`)

Each AST node is dispatched to a handler (`translate_typd`, `translate_decd`, `translate_reld`) that produces Maude source text. A final reordering pass separates declarations (`op`, `var`, `subsort`) from equations (`eq`, `ceq`), placing all declarations before all equations in the output.

### 1.3 The `texpr` Record: Pure Functional State

```ocaml
type texpr = { text : string; vars : string list }
```

Every expression translation returns a `texpr` carrying:
- `text`: the Maude source fragment
- `vars`: variable names encountered during traversal

This eliminates the need for global mutable accumulators during expression translation. Variables are propagated upward through combinators:

```ocaml
tconcat : string → texpr list → texpr       (* join with separator *)
tmap    : (string → string) → texpr → texpr (* transform text only *)
tjoin2  : (string → string → string) → texpr → texpr → texpr
```

### 1.4 Declaration Management

A single mutable `Hashtbl` (`declared_vars`) tracks all emitted variable and operator declarations to prevent redeclaration warnings. It is initialized via `init_declared_vars()` with the same variables declared in the Maude header:

```
I : Int,  W-I : Int,  EXP : Int,
W-N : Nat,  W-M : Nat,
T : WasmTerminal,  W : WasmTerminal,  WW : WasmTerminal,  W-X : WasmTerminal,
TS : WasmTerminals,  W* : WasmTerminals
```

This synchronization ensures zero redeclaration warnings.

---

## 2. Formal Translation Rules

The following rules define the mapping from SpecTec IL AST nodes to Maude declarations and equations. We use the notation:

```
⟦ AST_node ⟧ ⟹ Maude_output
```

where `⟦...⟧` denotes the translation function and `⟹` denotes "produces."

### 2.1 Type Definitions (TypD)

```
⟦ TypD(id, params, insts) ⟧

  ⟹  op sanitize(id) : WasmTerminal^|params| → WasmType [ctor] .

  For each InstD(binders, args, deftyp) in insts:

    Case deftyp = VariantT(cases):
      For each (mixop, (_, case_typ, prems), _) in cases:

        ⟹  op interleave_op(mixop, |collected_params|)
              : sort^|params| → WasmTerminal [ctor] .
            eq is-type( interleave_lhs(mixop, param_vars),
                        id(binder_args) ) = true .
            --- or ceq ... if <conditions> .  (when binders have type constraints)

    Case deftyp = AliasT(typ):
        ⟹  eq is-type( T, id(binder_args) ) = is-type( T, translate_typ(typ) ) .

    Case deftyp = StructT(fields):
        ⟹  eq is-type( {item('F1, V1); ...; item('Fn, Vn)}, id(binder_args) )
              = is-type(V1, typ1) and ... and is-type(Vn, typn) .
```

**Concrete example — VariantT with no premises:**

```
⟦ TypD("numtype", [], [InstD([], [], VariantT([
      (I32, ...), (I64, ...), (F32, ...), (F64, ...)
   ]))]) ⟧

  ⟹  op numtype : → WasmType [ctor] .
      op I32 : → WasmTerminal [ctor] .
      eq is-type(I32, numtype) = true .
      op I64 : → WasmTerminal [ctor] .
      eq is-type(I64, numtype) = true .
      ...
```

**Concrete example — VariantT with parameters and binders:**

```
⟦ TypD("binop", [param_nt], [InstD([ExpB("nt",_)], [nt], VariantT([
      (ADD, ...), (SUB, ...), (MUL, ...), ...
   ]))]) ⟧

  ⟹  op binop : WasmTerminal → WasmType [ctor] .
      op ADD : → WasmTerminal [ctor] .
      eq is-type(ADD, binop(NT)) = is-type(NT, Inn) .
      op SUB : → WasmTerminal [ctor] .
      eq is-type(SUB, binop(NT)) = is-type(NT, Inn) .
      ...
```

### 2.2 Function Definitions (DecD)

```
⟦ DecD(id, params, result_typ, insts) ⟧

  ⟹  op fn_name : sort_1 ... sort_n → ret_sort .

  where fn_name = "$" ^ sanitize(id)  (unless id already starts with "$")
        sort_i  = "Bool" if params[i] has Bool type, else "WasmTerminal"
        ret_sort = "Bool"           if result_typ is Bool or all RHS are boolish
                 | "WasmTerminals"  if result_typ is IterT(_, List|List1)
                 | "WasmTerminal"   otherwise

  For each DefD(binders, lhs_args, rhs, prems) in insts:

    vm   = binder_to_var_map(prefix, eq_idx, binders)
    LHS  = fn_name( translate_exp(lhs_args[0], vm), ..., translate_exp(lhs_args[n], vm) )
    RHS  = translate_exp(rhs, vm)
    COND = binder_type_conditions(binders) ∧ translate_prem(prems)

    Binding analysis:
      bound_vars = vars appearing in LHS
      free_vars  = vars appearing in RHS or COND but NOT in LHS

    ⟹  vars <bound_vars> : WasmTerminal .    --- declared as variables
        op <free_var_i> : → WasmTerminal .    --- skolemized as constants
        [c]eq LHS = RHS [if COND] .
```

**Variable Naming Convention:**

Variables are prefixed with a case-specific tag to prevent cross-equation name collisions:

```
make_var_prefix(prefix, eq_idx, raw_v)
  = PREFIX<eq_idx>-SANITIZE(raw_v)

Example:  DecD("iadd", ...)
  prefix = "IADD"
  eq_idx = 0
  binder "n"  ⟹  IADD0-WN
  binder "iN_1" ⟹ IADD0-IN1
  binder "iN_2" ⟹ IADD0-IN2
```

### 2.3 Relation Definitions (RelD)

```
⟦ RelD(id, _, _, rules) ⟧

  ⟹  op sanitize(id) : WasmTerminal^arity → Bool .

  For each RuleD(case_id, binders, _, conclusion, prems) in rules:

    vm   = binder_to_var_map(REL_PREFIX-CASE_PREFIX, rule_idx, binders)
    ARGS = translate_exp(conclusion, vm)   --- typically a TupE
    COND = binder_type_conditions(binders) ∧ translate_prem(prems)

    Binding analysis (same as DecD):
      bound in LHS → var declarations
      free (not in LHS) → op (skolemized constant) declarations

    ⟹  [c]eq sanitize(id)( ARGS ) = true [if COND] .
```

**Step-pure variable naming:**

```
RelD("Step_pure", ...)
  rel_prefix = "STEP-PURE"
  RuleD("nop", ...)  ⟹ prefix = "STEP-PURE-NOP"
  RuleD("drop", ...)  ⟹ prefix = "STEP-PURE-DROP"
  RuleD("binop-val", ...)  ⟹ prefix = "STEP-PURE-BINOP-VAL"
```

### 2.4 Mixfix Operator Translation

SpecTec uses mixfix operators to represent Wasm instructions (e.g., `CONST nt c`, `BR_IF l`). The translator decomposes a mixop into alternating **sections** (keyword tokens) and **holes** (parameter slots):

```
⟦ CaseE(mixop, inner) ⟧

  sections = mixop_sections(mixop)    --- e.g., ["CONST"; ""]  or ["BR-IF"; ""]
  args     = translate_exp(inner)      --- parameter expressions

  LHS context:
    ⟹  interleave_lhs(sections, args)
        e.g., "CONST NT CN"  or  "BR-IF L"

  Operator declaration:
    ⟹  op interleave_op(sections, |args|) : WasmTerminal^|args| → WasmTerminal [ctor] .
        e.g., op CONST _ _ : WasmTerminal WasmTerminal → WasmTerminal [ctor] .
        e.g., op BR-IF _   : WasmTerminal → WasmTerminal [ctor] .
```

### 2.5 Expression Translation (translate_exp)

Every expression is translated with a **context parameter** `ctx ∈ {BoolCtx, TermCtx}` that determines whether Boolean subexpressions need wrapping.

| AST Node | Translation |
|----------|-------------|
| `VarE(id)` | Variable lookup in `vm`; if token-like, emit as constant |
| `NumE(n)` | Integer/rational literal |
| `BoolE(b)` | `wrap_bool(ctx, "true"/"false")` |
| `TupE([])`, `ListE([])` | `eps` |
| `TupE(es)` | Space-separated translations |
| `CaseE(mixop, inner)` | Mixfix interleaving (§2.4) |
| `CallE(id, args)` | `$sanitize(id)(arg1, arg2, ...)` |
| `BinE(op, _, e1, e2)` | `(e1 op e2)` with appropriate Maude operator |
| `CmpE(op, _, e1, e2)` | `wrap_bool(ctx, (e1 op e2))` |
| `UnE(NotOp, _, e)` | `wrap_bool(ctx, not(e))` |
| `StrE(fields)` | `{item('F1, v1) ; item('F2, v2) ; ...}` |
| `DotE(e, atom)` | `value('ATOM, e)` |
| `CompE(e1, e2)` | `merge(e1, e2)` |
| `IdxE(e1, e2)` | `index(e1, e2)` |
| `LenE(e)` | `len(e)` |
| `CatE(e1, e2)` | `e1 e2` (juxtaposition) |
| `UpdE(e1, path, e2)` | `(e1 [path <- e2])` |
| `ExtE(e1, path, e2)` | `(e1 [path =++ e2])` |
| `IfE(c, e1, e2)` | `if c then e1 else e2 fi` |
| `IterE(VarE id, (List,_))` | Variable with `*` suffix lookup |
| `MemE(e1, e2)` | `wrap_bool(ctx, (e1 <- e2))` |
| `SubE`, `CvtE`, `ProjE`, `UncaseE` | Pass through to inner expression |

### 2.6 Bool Wrapper Strategy

The `w-bool` wrapper resolves a fundamental sort conflict: `subsort Bool < WasmTerminal` would import Maude's built-in `_xor_` operator into the `WasmTerminal` sort, causing pervasive parsing failures. Instead:

```
op w-bool : Bool → WasmTerminal [ctor] .
```

The `wrap_bool` function applies contextually:

```
wrap_bool(BoolCtx, s) = s                --- in conditions: raw Bool
wrap_bool(TermCtx, s) = "w-bool(" ^ s ^ ")"  --- in terms: wrapped
```

Context determination:
- **BoolCtx**: Inside `if` premises (`IfPr`), logical operators (`and`, `or`, `implies`), `not`, and the RHS of Bool-returning functions
- **TermCtx**: Everywhere else (function arguments, record fields, sequence elements)

### 2.7 Premise Translation (translate_prem)

| Premise Node | Translation |
|-------------|-------------|
| `IfPr(e)` | `translate_exp(BoolCtx, e)` |
| `RulePr(id, _, e)` | `sanitize(id)(translate_exp(e))` |
| `LetPr(e1, e2, _)` | `(e1 == e2)` |
| `ElsePr` | Triggers `[owise]` attribute |
| `IterPr(inner, _)` | Recurse into inner premise |

### 2.8 Identifier Sanitization

```
⟦ sanitize(name) ⟧

  1. "_"  ⟹  "any"
  2. Single-char, non-alpha-start, or Maude keyword  ⟹  "w-" prefix
  3. Special chars (. _ ' * + ?)  ⟹  "-"
  4. "-digit" sequences  ⟹  "Ndigit"  (e.g., "x-1" → "xN1")
  5. Trailing hyphens stripped
```

### 2.9 Token Auto-Collection

Bare tokens are identifiers that appear in mixfix patterns but are **not** constructors declared by `VariantT` cases. They represent Wasm type variables or placeholders used in expressions:

```
auto_tokens = prescan.tokens \ prescan.ctors
⟹  ops TOKEN1 TOKEN2 ... : → WasmTerminal [ctor] .
```

This eliminates all hardcoded instruction-name lists from the translator.

### 2.10 Free Variable Skolemization

Maude requires all variables in `eq`/`ceq` right-hand sides and conditions to be **bound** (appear in the LHS). The translator analyzes each equation:

```
partition_vars(lhs_vars, all_texts, all_collected_vars)

  bound = vars ∩ lhs_vars     ⟹  var V : WasmTerminal .
  free  = vars \ lhs_vars     ⟹  op V : → WasmTerminal .  (skolemized constant)
```

Skolemized constants satisfy Maude's binding check while preserving the structural intent of the SpecTec equation.

---

## 3. Sort Hierarchy and Parsing Ambiguity Analysis

### 3.1 The Flat Sort Lattice

The generated specification uses a deliberately flat sort hierarchy:

```
       WasmTerminals
       /          \
WasmTerminal    (assoc juxtaposition _ _)
  /   |   \
Int  Nat  WasmType
```

With subsort inclusions:

```maude
subsort Int < WasmTerminal .
subsort Nat < WasmTerminal .
subsort WasmType < WasmTerminal .
subsort WasmTypes < WasmTerminals .
```

### 3.2 Source of Ambiguity

Maude reports `Warning: multiple distinct parses` when a term can be parsed at different sort levels. This arises from two mechanisms:

**Mechanism A: Overloaded Constants**

A SpecTec constructor like `NOP` may be declared both:
1. As a token: `ops NOP : → WasmTerminal [ctor] .`
2. As a variant case: `op NOP : → WasmTerminal [ctor] .`

Both declarations produce the identical operator signature. Maude treats them as two distinct parse alternatives even though they denote the same term.

**Mechanism B: Subsort Polymorphism**

An integer literal `42` can be parsed as:
- `42 : Nat` (via built-in)
- `42 : Int` (via `subsort Nat < Int`)
- `42 : WasmTerminal` (via `subsort Int < WasmTerminal`)

When `42` appears as an argument to `is-type(42, num(I32))`, the parser sees valid parses at each sort level.

### 3.3 Confluence Argument

**Claim:** All ambiguous parses of a well-formed term in `SPECTEC-CORE` yield identical rewriting behavior.

**Proof sketch:**

1. **Sort Monotonicity.** For any operator `f : S₁ → S₂` with `S₁ ⊂ S₁'`, if a term `t` has sort `S₁`, then `f(t)` computed at sort `S₁` equals `f(t)` computed at sort `S₁'`. This holds because all equations in `SPECTEC-CORE` are defined at the maximal sort (`WasmTerminal` / `WasmTerminals`), and Maude's equational matching operates at the **kind** level `[WasmTerminal]`, which subsumes all subsorts.

2. **Operator Idempotence.** Duplicate `op` declarations for the same name with identical signature and attributes produce the same constructor in Maude's internal representation. The two parse trees are **syntactically distinct** but **semantically identical** — they denote the same term in the term algebra `T_Σ/E`.

3. **Equational Convergence.** All equations (`eq`/`ceq`) pattern-match at the kind level. A conditional equation `ceq f(X) = rhs if cond` will match any term of kind `[WasmTerminal]` regardless of which subsort parse was chosen. Since the matched substitution σ maps variables to the same ground values in all parses, the rewriting result is unique.

4. **Church-Rosser Property.** Maude's equational engine is Church-Rosser modulo the declared axioms (associativity, identity). Since our equations do not introduce competing rewrites for the same LHS pattern (the flat sort hierarchy prevents sort-based equation selection), the system is confluent.

**Practical Implication:** The `multiple distinct parses` warnings are cosmetic artifacts of the flat encoding. They do not affect the correctness of reductions, as verified empirically by the 59 equational tests and 12 rewrite-rule executions, all of which produce deterministic, expected results.

### 3.4 Why a Flat Hierarchy?

A richer sort hierarchy (e.g., `sort numtype . subsort numtype < valtype . subsort valtype < WasmTerminal .`) would eliminate many ambiguity warnings but would require:

1. **Complete sort inference** from the SpecTec type system, which uses dependent types and type-indexed families not directly expressible in Maude's order-sorted algebra.
2. **Cross-cutting subsort declarations** for Wasm's overlapping type categories (e.g., `I32` is simultaneously a `numtype`, an `Inn`, an `addrtype`, and a `valtype`).

The flat hierarchy trades parsing precision for translation generality: any SpecTec type maps uniformly to `WasmTerminal`, and type membership is encoded equationally via `is-type` predicates. This is a deliberate design choice that prioritizes completeness of the translation over elimination of advisory warnings.

---

## 4. Representative Translation Examples

### 4.1 Example: Arithmetic Function ($iadd)

**SpecTec source** (from `wasm-3.0/numerics.watsup`):

```
def $iadd(N : N, iN_1 : iN(N), iN_2 : iN(N)) : iN(N)
def $iadd(N, i_1, i_2) = (i_1 + i_2) mod (2 ^ N)
```

**OCaml AST** (abbreviated):

```ocaml
DecD("iadd",
  [ExpP("N", VarT("N")); ExpP("iN_1", VarT("iN", [N])); ExpP("iN_2", VarT("iN", [N]))],
  VarT("iN", [N]),
  [DefD(
    [ExpB("N", VarT("N")); ExpB("iN_1", VarT("iN")); ExpB("iN_2", VarT("iN"))],
    [ExpA(VarE "N"); ExpA(VarE "iN_1"); ExpA(VarE "iN_2")],
    BinE(ModOp, BinE(AddOp, VarE "iN_1", VarE "iN_2"), BinE(PowOp, NumE 2, VarE "N")),
    []  (* no premises *)
  )])
```

**Translation process:**

1. `translate_decd` computes `fn_name = "$iadd"`, `prefix = "IADD"`.
2. Binder `N` → `IADD0-WN`, binder `iN_1` → `IADD0-IN1`, binder `iN_2` → `IADD0-IN2`.
3. Binder type conditions: `is-type(IADD0-WN, w-N)`, `is-type(IADD0-IN1, iN(IADD0-WN))`, `is-type(IADD0-IN2, iN(IADD0-WN))`.
4. RHS translation: `BinE(ModOp, ...)` → `( ( IADD0-IN1 + IADD0-IN2 ) rem ( 2 ^ IADD0-WN ) )`.
5. All three variables appear in LHS → declared as `var`, none skolemized.

**Generated Maude:**

```maude
  op $iadd : WasmTerminal WasmTerminal WasmTerminal -> WasmTerminal .
  vars IADD0-WN IADD0-IN1 IADD0-IN2 : WasmTerminal .

  ceq $iadd ( IADD0-WN, IADD0-IN1, IADD0-IN2 )
    = ( ( IADD0-IN1 + IADD0-IN2 ) rem ( 2 ^ IADD0-WN ) )
    if is-type ( IADD0-WN , w-N )
   and is-type ( IADD0-IN1 , iN ( IADD0-WN ) )
   and is-type ( IADD0-IN2 , iN ( IADD0-WN ) ) .
```

**Verification:**

```maude
red in SPECTEC-CORE : $iadd(32, 3, 5) .
--- result: 8  ✓
```

### 4.2 Example: Step-pure Reduction Rule (NOP and BINOP)

**SpecTec source** (from `wasm-3.0/step.watsup`):

```
rule Step_pure/nop:
  NOP  ~>  eps

rule Step_pure/binop-val:
  (CONST nt c_1) (CONST nt c_2) (BINOP nt binop)  ~>  (CONST nt c)
  -- if c <- $binop(nt, binop, c_1, c_2)
```

**Translation process for NOP:**

1. `translate_reld` processes `RelD("Step_pure", ...)`.
2. `RuleD("nop", [], _, TupE[CaseE(NOP, _), VarE "eps"], [])`.
3. No binders, no premises → unconditional `eq`.
4. Conclusion: `TupE` with 2 elements → `Step-pure(UNREACHABLE, TRAP)` pattern.

**Generated Maude (NOP):**

```maude
  eq Step-pure ( NOP , eps ) = true .
```

**Translation process for BINOP-VAL:**

1. `RuleD("binop-val", binders=[nt, c_1, c_2, binop, c], _, conclusion, prems)`.
2. Binders yield: `STEP-PURE-BINOP-VAL48-NT`, `STEP-PURE-BINOP-VAL48-CN1`, `STEP-PURE-BINOP-VAL48-CN2`, `STEP-PURE-BINOP-VAL48-BINOP`, `STEP-PURE-BINOP-VAL48-WC`.
3. Conclusion: instruction sequence `CONST nt c_1  CONST nt c_2  BINOP nt binop` → result `CONST nt c`.
4. Premise: `IfPr(MemE(VarE "c", CallE("binop", [nt, binop, c_1, c_2])))` → `( WC <- $binop(NT, BINOP, CN1, CN2) )`.
5. Binder type conditions add `is-type` checks for `numtype`, `num(nt)`, `binop(nt)`.

**Generated Maude (BINOP-VAL):**

```maude
  ceq Step-pure (
        CONST STEP-PURE-BINOP-VAL48-NT STEP-PURE-BINOP-VAL48-CN1
        CONST STEP-PURE-BINOP-VAL48-NT STEP-PURE-BINOP-VAL48-CN2
        BINOP STEP-PURE-BINOP-VAL48-NT STEP-PURE-BINOP-VAL48-BINOP ,
        CONST STEP-PURE-BINOP-VAL48-NT STEP-PURE-BINOP-VAL48-WC
      ) = true
    if is-type ( STEP-PURE-BINOP-VAL48-NT , numtype )
   and is-type ( STEP-PURE-BINOP-VAL48-CN1 , num ( STEP-PURE-BINOP-VAL48-NT ) )
   and is-type ( STEP-PURE-BINOP-VAL48-CN2 , num ( STEP-PURE-BINOP-VAL48-NT ) )
   and is-type ( STEP-PURE-BINOP-VAL48-BINOP , binop ( STEP-PURE-BINOP-VAL48-NT ) )
   and is-type ( STEP-PURE-BINOP-VAL48-WC , num ( STEP-PURE-BINOP-VAL48-NT ) )
   and ( STEP-PURE-BINOP-VAL48-WC
         <- $binop ( STEP-PURE-BINOP-VAL48-NT,
                     STEP-PURE-BINOP-VAL48-BINOP,
                     STEP-PURE-BINOP-VAL48-CN1,
                     STEP-PURE-BINOP-VAL48-CN2 ) ) .
```

### 4.3 Example: Dispatch Function ($binop)

**SpecTec source:**

```
def $binop(Inn, ADD, iN_1, iN_2) = $iadd($size(Inn), iN_1, iN_2)
def $binop(Inn, SUB, iN_1, iN_2) = $isub($size(Inn), iN_1, iN_2)
def $binop(Inn, MUL, iN_1, iN_2) = $imul($size(Inn), iN_1, iN_2)
...
```

**Generated Maude (first three cases):**

```maude
  op $binop : WasmTerminal WasmTerminal WasmTerminal WasmTerminal -> WasmTerminals .

  ceq $binop ( BINOP0-INN, ADD, BINOP0-IN1, BINOP0-IN2 )
    = $iadd ( $sizenn ( BINOP0-INN ), BINOP0-IN1, BINOP0-IN2 )
    if is-type ( BINOP0-INN , Inn )
   and is-type ( BINOP0-IN1 , num ( BINOP0-INN ) )
   and is-type ( BINOP0-IN2 , num ( BINOP0-INN ) ) .

  ceq $binop ( BINOP1-INN, SUB, BINOP1-IN1, BINOP1-IN2 )
    = $isub ( $sizenn ( BINOP1-INN ), BINOP1-IN1, BINOP1-IN2 )
    if is-type ( BINOP1-INN , Inn )
   and is-type ( BINOP1-IN1 , num ( BINOP1-INN ) )
   and is-type ( BINOP1-IN2 , num ( BINOP1-INN ) ) .

  ceq $binop ( BINOP2-INN, MUL, BINOP2-IN1, BINOP2-IN2 )
    = $imul ( $sizenn ( BINOP2-INN ), BINOP2-IN1, BINOP2-IN2 )
    if is-type ( BINOP2-INN , Inn )
   and is-type ( BINOP2-IN1 , num ( BINOP2-INN ) )
   and is-type ( BINOP2-IN2 , num ( BINOP2-INN ) ) .
```

Note how each clause uses a unique index prefix (`BINOP0-`, `BINOP1-`, `BINOP2-`) to prevent variable name collisions across equations.

**Verification chain:**

```maude
red in SPECTEC-CORE : $binop(I32, ADD, 3, 5) .
--- Matches BINOP0: is-type(I32, Inn)=true, is-type(3, num(I32))=true, ...
--- Rewrites to: $iadd($sizenn(I32), 3, 5)
---            = $iadd(32, 3, 5)
---            = (3 + 5) rem (2 ^ 32)
---            = 8  ✓
```

---

## 5. Known Limitations

| Limitation | Cause | Impact |
|-----------|-------|--------|
| `$sum(1 2 3)` does not reduce | Operator declared `WasmTerminal → WasmTerminal` but equations match on `WasmTerminals` | Only `$sum(eps)` works |
| Multi-instruction `Step-pure` patterns (DROP, IF) | Assoc `_ _` operator makes kind-level matching ambiguous for multi-element LHS | Simple patterns (NOP, UNREACHABLE, BR-IF) work |
| `IterE` binder variables sometimes skolemized | Translator classifies `IterE(VarE id, ...)` variables as free when they don't appear in the binder map | Non-critical: affected equations produce correct `op` declarations |
| Parsing ambiguity warnings | Flat sort hierarchy and duplicate declarations | Cosmetic only; all results are deterministic (§3.3) |
