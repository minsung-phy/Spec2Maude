# Confirmed Stuck / Error Phase 1 Triage

Updated: 2026-05-22

이 문서는 broad rule concrete audit에서 나온 위험 상태부터 본 Phase 1 기록이다.

대상:

- `STACK_OVERFLOW`: 3개
- `MAUDE_EXIT_2`: 15개
- `TIMEOUT`: 1개

이번 Phase 1에서는 priority 항목을 source-valid focused probe로 다시 실행해서,
진짜 translator bug / 실제 limitation / 자동 sample bug를 분리했다.

## Latest Focused Artifact

```text
artifacts/phase1-error-triage-20260522_102830/summary.md
```

## 결과 요약

| 항목 | source-valid 재검증 | 결론 |
|---|---|---|
| `expr-ok-const-r0` | `Expr-ok-const(C0, CONST i32 0, i32)` rewrites to `valid` | broad audit sample bug |
| `step-read-array-fill-succ` | source-valid `ARRAY.FILL` one-step rewrites | broad audit sample bug |
| `clos-deftypes-r1` | `$clos-deftypes(eps)`, `$clos-deftypes(fib-type)`, `$clos-deftypes(fib-type fib-type)` rewrite | broad `search =>+` sample/RHS bug |
| `alloctypes-r1` | `$alloctypes(eps)` and `$alloctypes(fib-source-type)` rewrite | broad `search =>+` sample/RHS bug |
| `infer-fieldtype-ok-arg1-r0` | `$infer-fieldtype-ok-arg1(C0)` rewrites to `CTORMUTA0 CTORBOTA0` | broad sample/context bug |
| `step-read-array-new-elem-alloc` | rewrites to `CTORREFI31NUMA1(7) CTORARRAYNEWFIXEDA2(0, 1)` | generic translator bug fixed |
| `step-read-br-on-cast-succeed` | rewrites to `CTORREFI31NUMA1(7) CTORBRA1(1)` | generic translator bug fixed |
| `evalexprss-r1` | empty case passes; nonempty flat `expr**` probe remains stuck under `$evalexprss(...)` | nested sequence grouping limitation |
| `step-read-br-on-cast-fail-fail` | stack overflow or timeout on subtype-negative `otherwise` path | otherwise/negative-premise limitation |
| `infer-instrs-ok-arg0-r3` | remains as `$infer-instrs-ok-arg0(...)` | context witness synthesis limitation |
| remaining label/handler/return `Step_pure` and selected `Step_read` probes | PASS | broad audit sample bugs |

## Generic Fixes Applied

### 1. Record field variable namespace

Problem:

source-derived typed record projection equations reused global-looking field variables such as `F-TYPE-0`.
That meant different records with a `TYPE` field could accidentally share one Maude variable declaration.

Example before:

```maude
var F-TYPE-0 : Tagtype .
eq value('REFS, RECEleminstA2(F-TYPE-0, F-REFS-1)) = F-REFS-1 .
```

For `eleminst`, the `TYPE` field should be `Elemtype`, not `Tagtype`.
Because of the collision, `value('REFS, RECEleminstA2(CTORREFA2(...), refs))` did not reduce.

Fix:

record field variables are namespaced by the source record sort.

Example after:

```maude
var F-TAGINST-TYPE-0 : Tagtype .
var F-ELEMINST-TYPE-0 : Elemtype .
var F-ELEMINST-REFS-1 : SpectecTerminals .

eq value('REFS, RECEleminstA2(F-ELEMINST-TYPE-0, F-ELEMINST-REFS-1))
 = F-ELEMINST-REFS-1 .
```

This is generic and source-derived. It does not special-case `eleminst`, `$elem`, or `ARRAY.NEW_ELEM`.

### 2. Mixed-case constructor names are not variables

Problem:

The Maude variable extractor matched uppercase prefixes inside mixed-case generated constructor names.
For example `RECContextA13(...)` could contribute a fake variable token like `RECC`.
Then a ground source context `{}` looked unbound, and the scheduler inserted unnecessary witness inference:

```maude
$infer-reftype-sub-arg0(RT, TARGET) => RECContextA13(eps, ..., eps)
```

That blocked `step-read-br-on-cast-succeed` even though the source premises were independently executable.

Fix:

variable extraction now ignores partial uppercase matches inside larger mixed-case names.
After regeneration, `step-read-br-on-cast-succeed` uses the source-shaped order:

```maude
$infer-ref-ok-arg2(S, REF) => RT
/\ Ref-ok(S, REF, RT) => valid
/\ Reftype-sub(empty-context, RT, TARGET) => valid
```

The focused source-valid probe now passes.

### 3. Map helpers only unfold over operationally known sequences

Problem:

generated `$map-*` helpers used a broad non-empty check:

```maude
ceq $map-f(S) = f(index(S, 0)) $map-f(slice(S, 1, len(S) - 1))
  if S =/= eps .
```

For opaque source builtin results such as `$lanes(...)`, Maude could decide
`S =/= eps` even though the sequence structure was not really available.
This let the map helper unfold into ill-typed symbolic lane computations.

Fix:

the generator now emits:

```maude
ceq $map-f(S) = f(index(S, 0)) $map-f(slice(S, 1, len(S) - 1))
  if len(S) > 0 .
```

This still executes on concrete flat sequences, but it avoids blindly mapping
over source builtin results whose sequence structure is not operationally known.

### 4. Bool-valued source expressions get sort-safety guards in terminal defs

Problem:

source defs such as:

```spectec
def $ilt_(N, S, i_1, i_2) = $bool($signed_(N, i_1) < $signed_(N, i_2))
```

were lowered as unconditional equations over the broad `SpectecTerminal`
carrier. If `i_1` was an opaque builtin result such as `$lanes(...)`, the RHS
became an ill-sorted symbolic Bool wrapper. When such a term was concatenated
with a sequence, Maude could stack-overflow.

Fix:

the generator now adds a generic sort-safety condition for Bool expressions
that are lowered into terminal-valued source defs:

```maude
ceq $ilt(N, S, I1, I2) = $bool(w-bool($signed(N, I1) < $signed(N, I2)))
  if $signed(N, I1) < $signed(N, I2) : Bool .
```

This is not judgement-specific and does not special-case vector names. It
preserves the source typed-argument intent: the equation only fires when the
Bool expression is actually well-sorted in Maude.

## Remaining Real Limitations

### `evalexprss-r1`

`evalexprss-r1` still has a real execution issue for nonempty flat input.

Source:

```spectec
def $evalexprss(z, eps) = (z, eps)
def $evalexprss(z, expr* expr'**) = (z'', ref* ref'**)
  -- if (z', ref*) = $evalexprs(z, expr*)
  -- if (z'', ref'**) = $evalexprss(z', expr'**)
```

Why it is hard:

- `expr**` is a nested sequence: a sequence of `expr*` groups.
- Current C1 mostly represents sequences as flat `SpectecTerminals`.
- In flat form, Maude can split `expr* expr'**` with `expr* = eps`, so the recursive call can receive the same input again.
- Broad `search =>+` probes can stack-overflow on that path; the focused `red` probe currently remains stuck as `$evalexprss(...)`.

Classification:

```text
NESTED_SEQUENCE_GROUPING_LIMITATION
```

### `step-read-br-on-cast-fail-fail`

Source has an `otherwise` rule:

```spectec
rule Step_read/br_on_cast_fail-succeed:
  s; f; ref (BR_ON_CAST_FAIL l rt_1 rt_2)  ~>  ref
  -- Ref_ok: s |- ref : rt
  -- Reftype_sub: {} |- rt <: $inst_reftype(f.MODULE, rt_2)

rule Step_read/br_on_cast_fail-fail:
  s; f; ref (BR_ON_CAST_FAIL l rt_1 rt_2)  ~>  ref (BR l)
  -- otherwise
```

For a false cast, Maude should fail the succeed premise and then use the otherwise rule.
Current C1 does not have a source-preserving negative rewrite condition for “the previous relation premise does not hold”.
So Maude may try to prove the impossible subtype premise and recurse through `Heaptype_sub/trans` until stack overflow or timeout.

Classification:

```text
OTHERWISE_NEGATIVE_PREMISE_LIMITATION
```

### `infer-instrs-ok-arg0-r3`

Source:

```spectec
rule Instrs_ok/frame:
  C |- instr* : (t* t_1*) ->_(x*) (t* t_2*)
  -- Instrs_ok: C |- instr* : t_1* ->_(x*) t_2*
  -- Resulttype_ok: C |- t* : OK
```

The `$infer-instrs-ok-arg0` helper tries to infer the context `C` from `instr*` and the instruction type.
For the empty-instruction focused probe, the source relation permits many possible contexts, but the current helper has no source-derived way to choose one canonical context.

Classification:

```text
CONTEXT_WITNESS_SYNTHESIS_LIMITATION
```

### vector bitmask builtins

`$ivbitmaskop` and `$vbitmaskop` no longer crash. They now reduce to symbolic
terms involving source builtin declarations:

```maude
$irev(32, $inv-ibits(32, $ilt(... $lanes(...) ...) 0 ... 0))
```

The remaining stuckness is expected because `$lanes`, `$inv-ibits`, and `$irev`
are `hint(builtin)` source functions without a concrete backend implementation
in the current C1 runtime.

Classification:

```text
BUILTIN_NUMERIC_VECTOR_LIMITATION
```

## Invariants After Fix

Checked after regeneration:

- no `eq/ceq ... = valid`
- no `iter-empty` / `opt-empty`
- `step-from-step-pure-*` count remains 20
- no forbidden judgement/benchmark hardcoding in `translator_bs.ml`
- `scripts/run_c1_regression.sh` passes
- focused C1 probe matrix is now 27 PASS / 4 EXPECTED_STUCK after source-derived typed index lowering fixed the representative composite `localtype*` index and `Instr-ok/local.get` probes
- Phase 1 focused triage passes with only expected limitation/timeout rows
