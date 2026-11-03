# From SpecTec IL to Maude: Translation Map

This table is for reviewers. It lists the constructors of the SpecTec IL
abstract syntax, the Maude they are translated to, and the OCaml function
that implements each case. Use it to find the code for a translation rule in
the paper, or to check how a constructor is handled.

- IL abstract syntax: [`spectec/lib/il/ast.ml`](../spectec/lib/il/ast.ml)
- Translator: [`translator/`](../translator/). Each file is named after the IL
  syntactic category it translates (`typd.ml` for `TypD`, `decd.ml` for
  `DecD`, `reld.ml` for `RelD`, `prem.ml` for premises, `term.ml` for
  expressions and types, `iter.ml` for iterations). A lowering selected by a
  hint rather than by an IL constructor has its own file (`heatcool.ml` for
  `hint(k_heatcool)`). Generated iteration helpers are in `iter_helpers.ml`,
  and the reordering of Maude conditions is in one section of
  `maude/maude_il.ml`.
- Code locations are given as `file:function` in the current code.
- Cases that the translator rejects or omits are listed in section 8.

## Notation

| Symbol | Meaning |
| --- | --- |
| `⟦e⟧` | Maude term for IL expression `e` (`Term.translate_exp`) |
| `⟦t⟧` | Maude term that names IL type `t` (`Term.translate_typ`) |
| `⟦prs⟧` | Maude conditions for the premises `prs` (`Prem.translate_all`) |
| `S(t)` | Maude sort for IL type `t` (`Term.translate_sort`) |
| `x̂` | Maude name chosen for IL identifier `x` (fixed before translation). A name already in use gets the prefix `spectec-`; a constructor whose `spectec-` name is also in use is named after its syntax instead (e.g. `FUNC-func` for `FUNC` of `syntax func`) |
| `b` | Boolean condition: the Maude condition `b = true` |
| `u = v` | Equality condition |
| `P := u` | Matching condition: match `u` against pattern `P` |
| `u => P` | Rewrite condition |

The Maude shapes below are schematic. They omit sort coercions, boxing of
native values (`#_`), and the conditions generated from type annotations.

A source variable keeps its SpecTec name in upper case, including `*`, `?`,
`'`, and `_`: `instr*` is `INSTR*`, `instr'*` is `INSTR'*`, `t*?` is `T*?`,
and `val_1` is `VAL_1` (`prescan.ml:variable_base`). Maude accepts these
characters inside a variable token (Maude manual, Appendix B.2). When two
variables would get the same name, because they differ only in case (`C`/`c`)
or one source variable occurs with two Maude sorts, the later one gets a
`-N` suffix: `C-2`, `C_1-2`. Generated variables follow the same suffix rule;
the rest of a sequence after its head `x` is `X*-REST`.

## 1. Definitions

The translation visits the definitions of the script in order
(`def.ml:translate`).

| IL constructor | Maude output | Code |
| --- | --- | --- |
| `TypD x params insts` | `op x̂ : S(params) -> SpectecType .` and the output for each `inst` | `typd.ml:translate` |
| `InstD quants args deftyp` | output for `deftyp`, with type target `x̂(⟦args⟧)` and conditions from `quants` | `typd.ml:translate_inst` |
| `AliasT t` | `eq typecheck(V, x̂(..)) = typecheck(V, ⟦t⟧) .` If `hint(maude_sort)` boxes the elements of `t`, a second equation for the boxed value. | `typd.ml:translate_alias` |
| `StructT fields` | `ceq typecheck({ field('a1, V1) ; … }, x̂(..)) = true if typecheck(Vi, ⟦ti⟧) ∧ ⟦field premises⟧ .` If every field type can be composed and no field has `hint(maude_array)`, also an equation for `recordConcat`, used by `CompE`. | `typd.ml:translate_struct` |
| `VariantT cases`, named case `C` | `op Ĉ : S(t1) … S(tn) -> Sort [ctor] .` and `ceq typecheck(Ĉ(V1, …, Vn), x̂(..)) = true if … .` | `typd.ml:translate_constructor` |
| `VariantT cases`, hole-only case | `ceq typecheck(V, x̂(..)) = true if typecheck(V, ⟦t⟧) ∧ … .` | `typd.ml:translate_union` |
| `DecD f params t clauses` | Depends on the hints of `f` (table below) | `decd.ml:translate` |
| `RelD r params mixop t rules` | Depends on the relation kind (section 2) | `reld.ml:translate` |
| `RecD defs` | output for each `def` in `defs` | `def.ml:translate` |
| `GramD`, `HintD` | no output; hints are read before translation (section 7) | `def.ml:translate` |

### Function definitions (`DecD`)

| Kind of `f` | Declaration | Each clause `DefD quants args e prs` | Code |
| --- | --- | --- | --- |
| Ordinary | `op f̂ : S(params) -> S(t) .` | `ceq f̂(⟦args⟧) = ⟦e⟧ if ⟦prs⟧ ∧ ¬earlier .` with the complement of each earlier clause that can match (below). If `prs` contains `ElsePr`, the equation gets `[owise]` instead. | `decd.ml:equation_clause`, `decd.ml:ordered_clauses`, `decd.ml:complement` |
| `hint(maude_rule)` (the body needs rewriting) | `sort F-Config .` `subsort S(t) < F-Config .` `op f̂ : S(params) -> F-Config [frozen] .` | `crl f̂(⟦args⟧) => ⟦e⟧ if ⟦prs⟧ .` (`ElsePr` is rejected) | `decd.ml:translate_rule_clause` |
| A clause ends with `x <- es` and returns `x` (membership choice) | `sort F-Request .` `subsort S(t) < F-Request .` `op f̂ : S(params) -> F-Request [frozen] .` | `ceq f̂(⟦args⟧) = choose-f(⟦es⟧) if ⟦other prs⟧ .` and `rl choose-f(PREFIX X SUFFIX) => X .` Any element of `es` can be returned. | `decd.ml:translate_choice_clause` |
| `hint(builtin)` | `op f̂ : S(params) -> S(t) .` | no equations; the body is written by hand in `translator/backend/builtins.maude` | `decd.ml:translate` |

`hint(maude_kind)` makes the declaration partial (`~>` instead of `->`), and so do case premises added to a clause (section 7).

Function clauses are a sequential pattern match: a clause applies only if no
earlier clause does (the SpecTec paper; `spectec/lib/il/eval.ml`,
`reduce_exp_call`). Maude equations are unordered, so an ordinary clause
carries, for every earlier clause whose head can match the same input
(`reld.ml:source_overlap` on the source patterns, including disjoint
constructor types such as `Inn` and `Fnn`, and `reld.ml:inputs_may_overlap` on
the translated heads), the negation of that clause: a disequality for each
ground part of the earlier head that is a variable here, and the negation of
each earlier condition.

```
def $inv_jsize(8) = I8      def $inv_jsize(n) = $inv_isize(n)
ceq inv-jsize(N) = inv-isize(N) if N =/= 8 /\ N =/= 16 .
```

One head must be an instance of the other, and the earlier conditions must be
negatable (no binding); otherwise the clause is rejected (section 8). A
negation can repeat a condition that the clause's own conditions already imply
(the two clauses of `$signed_`); it is redundant, not wrong.

Case premises added for an earlier clause's result (section 7) are left out of
its negation: a clause whose premises hold is selected, and a failing result
check leaves the call stuck rather than enabling a later clause. For the same
reason a clause after such an overlapping clause states its complements
instead of using `[owise]`. An earlier clause with a case premise inside a
premise is rejected when a complement is needed (section 8).

`ElsePr` in a function clause means that no earlier clause applies. Maude's
`[owise]` means that no other equation of the operator applies, earlier or
later. The two agree when the `ElsePr` clause is the last clause of its
function. This holds for all 30 such clauses in the WebAssembly
specification, but the translator does not check it.

## 2. Relations and rules

The relation kind comes from the relation's notation and hints
(`prescan.ml:classify_relation`). In each rule, the conclusion `e` is split
into inputs `ins` and outputs `outs`.

| Relation kind | How it is selected | Declaration | `RuleD` with premises `prs` | Code |
| --- | --- | --- | --- | --- |
| Execution | notation `~>` or `~>*` | `sort R-Request .` `subsort S(outs) < R-Request .` `op r̂ : S(ins) -> R-Request [frozen] .` | `crl r̂(⟦ins⟧) => ⟦outs⟧ if ⟦prs⟧ .`; if `outs` is not a structural pattern, `crl r̂(⟦ins⟧) => RESULT if ⟦prs⟧ /\ RESULT := ⟦outs⟧ .` with `RESULT : S(outs)`, so the rule applies only where `outs` is defined | `reld.ml:lower_execution_rule`, `reld.ml:execution_statement` |
| Compute | `hint(maude_compute)` | `op r̂ : S(ins) ~> S(outs) .` | `ceq r̂(⟦ins⟧) = ⟦outs⟧ if ⟦prs⟧ .` | `reld.ml:translate_rule` |
| Check | `hint(maude_check)` | `op r̂ : S(e) ~> Bool .` | `ceq r̂(⟦e⟧) = true if ⟦prs⟧ .` | `reld.ml:translate_rule` |

A relation that matches none of these kinds is not translated (section 8).
For each relation, `def.ml:translate` calls `reld.ml:translate` for the
rules without `hint(k_heatcool)` and then
`heatcool.ml:translate_relation` for the rules with them (see below).

### `ElsePr` in execution relations

In an execution relation, `ElsePr` must be the first premise of its rule.
It means that no earlier rule of the same relation applies. The translator
states this directly. For each earlier rule that can match the same input, it
adds the **negation of that rule's conditions** to the conditions of the
`ElsePr` rule (`reld.ml:direct_complement`). If the negation cannot be
written as a condition (for example, when the earlier rule matches a sequence
pattern that can be split in more than one way), it uses a generated
predicate `r̂-r-enabled` instead, named after the earlier rule `R/r` (e.g.
`Step-read-throw-ref-handler-catch-enabled`). That predicate is defined by the earlier
rule's conditions and an `[owise]` equation that returns `false`
(`reld.ml:helper_statements`).

| Stage | What must hold for the translation to keep the meaning | Code |
| --- | --- | --- |
| 1. Skip earlier rules that cannot match | A rule is skipped only if its input patterns cannot match the same input. When the analysis is unsure, the rule is kept. | `reld.ml:source_overlap`, `reld.ml:inputs_may_overlap` |
| 2. Negate the conditions of an earlier rule | The negation is exact. A comparison is negated by its dual only if it is total (numbers, `==`, `=/=`); any other condition `b` becomes `b =/= true`, which also holds when `b` is undefined. A matching condition is shared only if its pattern has a unique decomposition. | `reld.ml:direct_complement`, `reld.ml:negate_comparison`, `reld.ml:unique_match_pattern` |
| 3. Fall back to `r̂-r-enabled` | `r̂-r-enabled(ins)` is `true` exactly when the earlier rule's conditions hold. An earlier rule with a rewrite condition cannot be used this way and is rejected. | `reld.ml:helper_statements` |

The negated conditions of an earlier rule leave out the case premises added for
its output (section 7), as for function clauses; an earlier rule with a case
premise inside a premise is rejected.

Rules with `hint(k_heatcool)` are not counted as
earlier rules. In the WebAssembly specification, no relation has both
(`ElsePr` occurs only in `Step_pure` and `Step_read`; the hint only in
`Step`, `Steps`, and `Eval_expr`).

### Rules selected by hints

| Hint | Meaning | Code |
| --- | --- | --- |
| `hint(maude_subsume)` on a rule of a computed relation | The rule defines a separate check operator. A premise whose outputs are already known calls this check (section 3). | `reld.ml:translate` |
| `hint(maude_trans "C" …)` on a transitivity rule of a checked relation | The other rules are emitted under a separate operator `r̂-step`, and `ceq r̂(xs) = true if r̂-step(xs)` links the two. The transitivity rule becomes `ceq r̂(x, z) = true if y` ranges over the listed constructors `∧ typecheck(y, t) ∧ y =/= x ∧ y =/= z ∧ r̂-step(x, y) ∧ r̂(y, z)`, where `t` is the type of `y`. | `reld.ml:translate_trans`, `reld.ml:step_bridge` |
| `hint(k_heatcool)` on a rule with an execution premise | A context rule (its only premise steps the same relation) is translated as in "Context rules with `hint(k_heatcool)`"; any other rule as in "Split rules with `hint(k_heatcool)`" below. | `heatcool.ml:translate_relation`, `hintd.ml:is_kept_rule` |

### Split rules with `hint(k_heatcool)`

The rewriting logic embedding of the K book (Section 5.4.5). Plug is an
equation. Split is an equation for a `~>` relation (it only takes the
configuration apart; the inner relation's rule is the step) and a rule for a
`~>*` relation (its reflexive and transitive rules both apply to one request)
(`heatcool.ml:heating`, `heatcool.ml:heats_by_equation`).

Such a rule `r̂(ins) => outs` has execution premises `inner(ins') => outs'`.
It is translated so that the inner step is taken by rewriting, and the
remaining premises are evaluated after it returns. The premises keep their
source order.

| Statement | Maude | Code |
| --- | --- | --- |
| Split (first execution premise) | `ceq r̂(⟦ins⟧) = inner(⟦ins'⟧) ~> hole-r(C) if ⟦earlier premises⟧ .` for `~>`, `crl [split-r] : r̂(⟦ins⟧) => inner(⟦ins'⟧) ~> hole-r(C) if ⟦earlier premises⟧ .` for `~>*`. `C` holds the bound variables that later premises use. `_~>_` is frozen in the hole. | `heatcool.ml:heatcool_rule` |
| Split guard, inner relation on an instruction sequence | an extra condition `identifyInner(⟦ins'⟧)`, a `Bool` operator with one equation `eq identifyInner(⟦ins of r'⟧) = true` per rule `r'` of the inner relation, conditional on the equational premises of `r'` over its input variables only and on the premises that fix how many values it takes (as in `identifyFocus`, e.g. `M = size(T_1*)` for `val^m (BLOCK bt instr*)`). A rule whose extent is not fixed (below) has none. On an input that no inner rule matches it stays unreduced, so the split does not apply. | `heatcool.ml:identify_statements` |
| Unheat (`~>` split) | `eq unheat(inner(⟦ins'⟧) ~> hole-r(C)) = ⟦ins⟧ .`: the configuration that a split request stands for, for drivers that observe it between steps | `heatcool.ml:heatcool_rule` |
| Next execution premise | `eq ⟦outs'⟧ ~> hole-r-inner(C) = inner2(⟦ins''⟧) ~> hole-r-inner2(C') .` With several execution premises, each hole is named after the relation it waits for. | `heatcool.ml:heatcool_rule` |
| Plug (after the last execution premise) | `eq ⟦outs'⟧ ~> hole-r-inner2(C) = ⟦outs⟧ .`, with the remaining premises as conditions | `heatcool.ml:heatcool_rule` |

A context rule (a rule whose execution premise steps a part of the
instruction sequence, such as `Step/ctxt-instrs`) is translated differently.
`identifyFocus` finds the instruction to step and splits the sequence into
`PREFIX`, focus, and `POSTFIX`. For a `~>` relation it has one
`eq identifyFocus(…) = { … }` (or `ceq`) for each rule of the relations that
can step a focus, and the split is
`ceq r̂(c) = r̂(focus) ~> hole(PREFIX, POSTFIX) if { PREFIX | focus | POSTFIX } := identifyFocus(…) …`
(`rl`/`crl` with a rewrite condition for a `~>*` relation). A rule whose
operands or trailing instructions have no fixed length (`val* TRAP instr*` of
trap-instrs; throw_ref-instrs) overlaps `PREFIX` and `POSTFIX`, so an input
splits in several ways, each a different successor. It has no `identifyFocus`
or identify equation; instead it is one rule through its bridges
(`crl r̂(z ; val* TRAP instr*) => z ; TRAP …`) and one inside the context
(`crl r̂(z ; PREFIX val* TRAP instr* POSTFIX) => z ; PREFIX TRAP POSTFIX …`),
which keep all splits (`heatcool.ml:absorbed_rules`). The plug puts the
result back between `PREFIX` and `POSTFIX`, and
`eq unheat(R ~> hole(PREFIX, POSTFIX)) = unheat(R) ~> hole(PREFIX, POSTFIX) .`
(`heatcool.ml:translate_pattern`, `heatcool.ml:context_transitions`). Which
rules are context rules, and their focus patterns, is decided before
translation (`hintd.ml:scan_contexts`, `hintd.ml:scan_heatcool`).

### Context rules with `hint(k_heatcool)`

The K embedding of the K book (Section 5.4.6) for a context rule
`R: C[x] ~> C'[x']  -- R: x ~> x'` whose conclusion input is one element `E`
of the sequence of the relation's split-rule sequence context
(`hintd.ml:scan_kembedding`). The driver state `kstate(c, K)` keeps the
configuration around the next redex and the holes taken off it. Such a rule
gets no focus pattern.

| Statement | Maude | Code |
| --- | --- | --- |
| Instrs heating | `ceq kstate(z ; PREFIX E POSTFIX, K) = kstate(z ; E, hole(PREFIX, POSTFIX) K) if _or-else_(PREFIX =/= eps, POSTFIX =/= eps) /\ closed-r(x) = false .` (both operands are total; `or-else` of `EXT-BOOL` gives the value of `_or_` without normalizing it) | `heatcool.ml:kembedding_rule` |
| Heating | `ceq kstate(⟦C[x]⟧, K) = kstate(⟦x⟧, hole-r(C) K) if closed-r(x) = false .` | `heatcool.ml:kembedding_rule` |
| Cooling | `ceq kstate(⟦x'⟧, hole-r(C) K) = kstate(⟦C'[x']⟧, K) if closed-r(x') = true .` | `heatcool.ml:kembedding_rule` |
| Closed bodies | `eq closed-r(b) = true .` for each focus pattern of the sequence context whose trigger is `E`'s constructor, `b` its body; `eq closed-r(x) = false [owise] .` Assumed: no step of `R` applies to such a body alone. | `heatcool.ml:closed_bodies` |
| Instrs cooling | `eq kstate(z ; s, hole(PREFIX, POSTFIX) K) = kstate(z ; PREFIX s POSTFIX, K) [owise] .` | `heatcool.ml:kembedding_statements` |
| Request | `ceq kstate(c, K) = kstate(r̂(c), K) if plug-first(K) = false [owise] .`: when no other equation applies and no sequence hole waits, the configuration becomes a request, which the split equations focus and one rule of the relation steps in place. `kstate`'s first argument is not frozen. | `heatcool.ml:kembedding_statements` |
| Cool all | `cool-all(unheat(r), K)` cools every hole; it is the source configuration of `kstate(r, K)`. | `heatcool.ml:kembedding_statements` |

## 3. Premises

Premises are translated left to right (`prem.ml:translate_prems`). An `IfPr`
or `LetPr` whose variables are not yet bound waits until a later `IfPr` or
`LetPr` binds them. A `RulePr`, `ElsePr`, or `IterPr` is never moved:
it is rejected if an earlier premise is still waiting. A call of a
`hint(maude_rule)` function is allowed only as a top-level equality in an
`IfPr` (below).

| IL constructor | Maude condition | Code |
| --- | --- | --- |
| `LetPr quants p e` | the conditions of `p` as a pattern for `⟦e⟧` (below) | `prem.ml:translate_letpr` |
| `RulePr r args mixop e`, execution relation | `r̂(⟦ins⟧) => ⟦outs⟧` | `prem.ml:translate_known_rulepr` |
| `RulePr r args mixop e`, computed relation, outputs known | `⟦outs⟧ = r̂(⟦ins⟧)` | `prem.ml:translate_known_rulepr` |
| `RulePr r args mixop e`, computed relation, outputs unknown | `⟦outs⟧ := r̂(⟦ins⟧)` | `prem.ml:translate_known_rulepr` |
| `RulePr r args mixop e`, computed relation with a `maude_subsume` rule, outputs known | `check(⟦ins⟧, ⟦outs⟧)` | `prem.ml:translate_known_rulepr` |
| `RulePr r args mixop e`, checked relation | `r̂(⟦e⟧)` | `prem.ml:translate_known_rulepr` |
| `RulePr` that uses `xs[i]` with `xs` known and `i` unbound | first `PREFIX Y SUFFIX := ⟦xs⟧` and `I := size(PREFIX)`, so `i` ranges over the valid indices | `prem.ml:bind_free_indices` |
| `ElsePr` | marks the rule; see section 2 (relations) and section 1 (`[owise]` for functions) | `prem.ml:translate_barrier` |
| `IterPr pr (iter, gens)`, all sources known | `helper(⟦captures⟧, ⟦sources⟧)`: a generated helper that checks `pr` for every element (section 6) | `prem.ml:translate_barrier`, `iter.ml:translate_premise` |
| `IterPr pr (iter, gens)`, one source unbound, `iter` is `^n` or there are two or more generators | `⟦source⟧` as a pattern for a generated helper that computes it from the other sources (section 6) | `prem.ml:translate_barrier` |

### `IfPr e`

`prem.ml:classify_ifpr` tries these cases in order and returns the first
that applies; `prem.ml:translate_ifpr` then translates that case.

| Shape of `e` | Maude condition |
| --- | --- |
| `f(args) = e'` or `e' = f(args)`, `f` has `hint(maude_rule)` | `f̂(⟦args⟧) => ⟦e'⟧` (`e'` may be a pattern) |
| a call of a `maude_rule` function anywhere else in `e` | rejected |
| `x <- es`, `es` not yet bound | wait |
| `x <- es`, `x` unbound, where choice is enabled (`bind_membership`: execution rules, the check helpers of their `IterPr`s, and `k_heatcool` focus patterns) | `PREFIX ⟦x⟧ SUFFIX := ⟦es⟧`: any element can be chosen; rejected elsewhere |
| `e1 ∧ e2`, not all variables bound | `⟦IfPr e1⟧` and `⟦IfPr e2⟧`, in the order in which their variables become bound |
| `f(args) = e'` or `e' = f(args)`, an argument unbound, `e'` known | if `f` has `hint(inverse g)`: the argument as a pattern for `ĝ(…, ⟦e'⟧)`, then `⟦e⟧`; otherwise wait |
| `p = e'` or `e' = p`, `p` has unbound variables, `e'` known | `p` as a pattern for `⟦e'⟧` (below) |
| all variables bound | `⟦e⟧` |
| otherwise | wait |

### Expressions as patterns

When an expression `p` has unbound variables, it is used as a pattern for a
known value `u` (`prem.ml:bind_pattern`). An argument of a function clause
head or a type instance is a pattern if it is one, and otherwise a fresh
variable bound in this way (`prem.ml:bind_head_argument`). Relation inputs
use the same scheme, and may also contain computed fields that are compared
after matching (`reld.ml:translate_inputs`). Most expressions become a matching
condition `⟦p⟧ := u` with the same constructors as `⟦p⟧`. Some arithmetic
and conversion expressions cannot be matched, so the translator computes the
unbound part from `u` instead:

| Shape of `p` | Maude conditions |
| --- | --- |
| all variables bound | `⟦p⟧ = u` |
| `e?` without a generator | `u == nil or u == ⟦e⟧ ?` |
| `e : t1 <:> t2` (numeric conversion) | `e` as a pattern for `u : t2 <:> t1` |
| `(e!C).0`, `C` with one argument | `e` as a pattern for `Ĉ(u)`, or for `u` if `C` is hole-only |
| `x * k` or `k * x` (natural or integer), `k` known | `k =/= 0`, `x` as a pattern for `u quo ⟦k⟧`, then `⟦p⟧ = u` |
| `f(args)`, `f` has `hint(inverse g)` | the missing argument as a pattern for `ĝ(…, u)`, then `⟦p⟧ = u` |
| `IterE` | the variables of the body are recovered by a generated helper (section 6) |
| constructors, tuples, sequences, records | `⟦p⟧ := u`; parts that are computed are matched to fresh variables and then compared |

## 4. Expressions

`Term.translate_exp` has one case per constructor. Values of Boolean, number,
and text type use Maude's built-in operations (`term.ml:native_exp`). All
other expressions are handled by `term.ml:translate_value`.

| IL constructor | Maude term | Code |
| --- | --- | --- |
| `VarE x` | variable `X̂ : S(t)` | `term.ml:translate_value` |
| `BoolE b`, `NumE n`, `TextE s` | Maude literal | `term.ml:native_exp` |
| `UnE op e` | `op(⟦e⟧)` (Maude built-in) | `term.ml:native_exp` |
| `BinE op e1 e2` | `⟦e1⟧ op ⟦e2⟧` (Maude built-in); nat `-` and nat/int `/` are rejected (section 8) | `term.ml:native_exp`, `term.ml:translate_binop` |
| `CmpE op e1 e2` | `⟦e1⟧ op ⟦e2⟧`; `==`/`=/=` for equality | `term.ml:native_exp` |
| `TupE es` | `tuple(⟦e1⟧ … ⟦en⟧)` | `term.ml:translate_value` |
| `ProjE e i` | `⟦e⟧ . i` | `term.ml:translate_value` |
| `CaseE C e`, named `C` | `Ĉ(⟦e1⟧, …, ⟦en⟧)`; an evaluated `Unchecked` one also adds the case premises (section 7) | `term.ml:translate_value` |
| `CaseE C e`, hole-only `C` | `⟦e⟧` | `term.ml:translate_value` |
| `UncaseE e C`, hole-only `C` | `⟦e⟧` | `term.ml:translate_value` |
| `OptE None` / `OptE (Some e)` | `nil` / `⟦e⟧ ?` | `term.ml:translate_value` |
| `StrE fields` | `{ field('a1, ⟦e1⟧) ; … }` | `term.ml:translate_value` |
| `DotE e a` | `⟦e⟧ . 'a` | `term.ml:translate_value` |
| `StrE fields`, `DotE e a`, `LenE`, `IdxE`, `SliceE`, `UpdE` on a `maude_array` or `maude_map` field | see "Fields with `hint(maude_array)`" and "Fields with `hint(maude_map)`" below | `term.ml:translate_value`, `term.ml:translate_update` |
| `CompE e1 e2` | `recordConcat`, `optionConcat`, or sequence concatenation, by type | `term.ml:translate_composition` |
| `ListE es` | `⟦e1⟧ … ⟦en⟧` (sequence) | `term.ml:translate_value` |
| `LiftE e` | sequence lift of `⟦e⟧` | `term.ml:translate_value` |
| `MemE e es` | `occurs(⟦e⟧, ⟦es⟧)` (prelude membership test) | `term.ml:native_exp` |
| `LenE e` | `size(⟦e⟧)` | `term.ml:translate_value` |
| `CatE e1 e2` | `⟦e1⟧ ⟦e2⟧` (sequence concatenation) | `term.ml:translate_value` |
| `IdxE e i` | `⟦e⟧[⟦i⟧]` | `term.ml:translate_value` |
| `SliceE e i n` | `⟦e⟧[⟦i⟧ : ⟦n⟧]` | `term.ml:translate_value` |
| `UpdE e path e'` | nested `_[_=_]`, `_[_:_=_]`, `_[._=_]` along `path` | `term.ml:translate_update` |
| `ExtE e path e'` | update of `path` with (value at `path`) `⟦e'⟧` | `term.ml:translate_extension` |
| `CallE f args` | `f̂(⟦args⟧)`; an argument or result typed by a syntax parameter `X` is one value, boxed by `seq(…)` / unboxed by `unseq(…)` when `X` is a sequence type | `term.ml:translate_value`, `term.ml:syntax_parameter_positions` |
| `IterE e (iter, gens)` | see section 6 | `iter.ml:translate_term` |
| `CvtE e t1 t2` | `⟦e⟧ : t1 <:> t2` | `term.ml:native_exp` |
| `SubE e t1 t2` | `⟦e⟧`, when `t1` and `t2` have the same Maude representation | `term.ml:translate_value` |

### Paths

| IL constructor | Maude term (selection) | Code |
| --- | --- | --- |
| `RootP` | the base value | `term.ml:translate_select` |
| `IdxP p i` | `⟦p⟧[⟦i⟧]` | `term.ml:translate_select` |
| `SliceP p i n` | `⟦p⟧[⟦i⟧ : ⟦n⟧]` | `term.ml:translate_select` |
| `DotP p a` | `⟦p⟧ . 'a` | `term.ml:translate_select` |

### Fields with `hint(maude_array)`

`hint(maude_array)` on a sequence field `f` of a record type (`{.., f t* hint(maude_array)}`) stores `f` as
`sized-array(size, A)`, where `A` is a prelude `ARRAY{Nat, Zero}` whose entries
equal to `# 0` are absent (`backend/spectec-semantics.maude`, `SPECTEC-ARRAY`).

| IL | Maude | Code |
| --- | --- | --- |
| `LenE (DotE e f)` | `array-size(⟦e⟧ . 'f)` | `term.ml:translate_value` |
| `IdxE (DotE e f) i` | `array-read(⟦e⟧ . 'f, ⟦i⟧, 1)` | `term.ml:translate_value` |
| `SliceE (DotE e f) i n` | `array-read(⟦e⟧ . 'f, ⟦i⟧, ⟦n⟧)` | `term.ml:translate_value` |
| `UpdE e (SliceP (DotP p f) i n) e'` | `p` updated with `[. 'f = array-write(⟦p⟧ . 'f, ⟦i⟧, ⟦n⟧, ⟦e'⟧)]` | `term.ml:translate_update` |
| `UpdE e (DotP p f) e'` | `p` updated with `[. 'f = array-of(⟦e'⟧)]` | `term.ml:translate_update` |
| field `f` of `StrE`, value `0^n` | `sized-array(⟦n⟧, empty)` | `term.ml:translate_stored_value` |
| field `f` of `StrE`, value `e 0^n` | `array-grow(⟦e⟧, ⟦n⟧)`, with `⟦e⟧` by this row set | `term.ml:translate_stored_value` |
| field `f` of `StrE`, value `e.f'` of another array field | the stored array of `e.f'` | `term.ml:translate_stored_value` |
| field `f` of `StrE`, other value `e` | `array-of(⟦e⟧)` (the sequence becomes an array) | `term.ml:translate_stored_value` |
| field `f` of a `StrE` pattern | the variable binds the stored array; its later uses are written as `e.f` before translation (section 7) | `prem.ml:translate_field_patterns`, `def.ml:stored_script` |

`0` is `NumE 0`, possibly under `SubE`, `CvtE`, or an argument case such as
`%_byte(0)`. Every other use of the field is rejected (section 8).

### Fields with `hint(maude_map)`

`hint(maude_map)` on a sequence field `f` of a record type stores `f` as
`sized-map(size, M)`, where `M` is a prelude `MAP{Nat, Terminal}` (entry
operator renamed `_|=>_`) with an entry for every index `0 .. size-1`
(`backend/spectec-semantics.maude`, `SPECTEC-MAP`). Since every index has
exactly one entry, `map-read` and `map-write` match the entry with that key
directly instead of the prelude `M[I]` and `insert`, which also search for a
duplicate key. A missing index has no equation, so an out-of-range read or
write gives no value, as in the source. `hint(maude_map)` on a `DecD` whose clauses return
such a field (`def $funcinst(state) : funcinst*`) makes its calls map values.

| IL | Maude | Code |
| --- | --- | --- |
| `LenE (DotE e f)`, `LenE (CallE g ..)` | `map-size(⟦e⟧ . 'f)`, `map-size(ĝ(..))` | `term.ml:translate_value`, `term.ml:stored_value` |
| `IdxE (DotE e f) i`, `IdxE (CallE g ..) i` | `map-read(⟦e⟧ . 'f, ⟦i⟧)`, `map-read(ĝ(..), ⟦i⟧)` | `term.ml:translate_value`, `term.ml:stored_value` |
| `UpdE e (IdxP (DotP p f) i) e'` | `p` updated with `[. 'f = map-write(⟦p⟧ . 'f, ⟦i⟧, ⟦e'⟧)]` | `term.ml:translate_update` |
| path `IdxP (DotP p f) i` below an update (`s[.f[i].g = e']`) | selected by `map-read(⟦p⟧ . 'f, ⟦i⟧)`, written back by `map-write` | `term.ml:translate_select`, `term.ml:translate_update` |
| `UpdE e (DotP p f) e'` | `p` updated with `[. 'f = map-of(⟦e'⟧)]` | `term.ml:translate_update` |
| field `f` of `StrE`, value `e.f'` of another map field | the stored map of `e.f'` | `term.ml:translate_stored_value` |
| field `f` of `StrE`, value `e s` with `e` a map field | `map-append(⟦e⟧, ⟦s⟧)` | `term.ml:translate_stored_value` |
| field `f` of `StrE`, other value `e` | `map-of(⟦e⟧)` | `term.ml:translate_stored_value` |
| `CompE` of the record (`s ++ {f x}`) | `recordConcat` with `map-concat(L . 'f, R . 'f)` for `f` | `typd.ml:translate_struct_composition` |
| clause result of a `hint(maude_map)` `DecD` | the stored map of the returned field | `decd.ml:translate_result` |
| field `f` of a `StrE` pattern | as for `maude_array` | `def.ml:stored_script` |

Every other use of the field or of a call of the definition is rejected
(section 8).

## 5. Types, arguments, and parameters

| IL constructor | Maude | Code |
| --- | --- | --- |
| `VarT x args` | `x̂(⟦args⟧)`, or a variable for a type parameter | `term.ml:translate_typ` |
| `BoolT`, `NumT t`, `TextT` | `bool`, `nat`/`int`/`rat`/`real`, `text` | `term.ml:translate_typ` |
| `TupT fields` | one component for each field | `term.ml:translate_components` |
| `IterT t Opt` / `IterT t List`, as a type argument | `iterOpt(⟦t⟧)` / `iterList(⟦t⟧)` | `term.ml:translate_check_typ` |
| A value `v` of type `t?` (guard) | `typecheck(v, iterOpt(⟦t⟧))`: `nil`, or `V ?` with `typecheck(V, ⟦t⟧)` | `iter.ml:translate_conditions` |
| `IterT t iter`, as a sort | the sort of the sequence or option of `t` | `term.ml:translate_sort` |
| `ExpA e` / `TypA t` | `⟦e⟧` / `⟦t⟧`, keeping the source type name (an alias such as `localidx` is not expanded; its `typecheck` equation resolves it) | `term.ml:translate_arg`, `term.ml:translate_check_typ` |
| `ExpP x t` / `TypP x` | variable of sort `S(t)` / of sort `SpectecType` | `param.ml` |
| `DefP`, `DefA` | removed before translation: each call with a function argument uses a copy of the definition specialized to that function | `decd.ml:specialize` |

## 6. Iterations

An `IterE` with iterator `iter` (`?`, `*`, `+`, or `^n`) and generators
`x <- xs` is translated in one of three ways (`iter.ml:translate_term`):

| Case | Maude term |
| --- | --- |
| The body only rewraps the generator variable (`x`, a hole-only `CaseE`/`UncaseE` of `x`, a `SubE` of `x` with the same representation, or a nested identity iteration) | `⟦xs⟧` |
| `e^n` without a generator and without an index variable | a repeat operation: `n` copies of `⟦e⟧` |
| otherwise | a call to a generated helper |

An `IterPr` always becomes a call to a generated helper (section 3).

Maude has no built-in map over a sequence, so the helper is a recursive
function with one equation for the empty sequence and one for a non-empty
sequence:

```maude
eq map-f(C, nil) = nil .
eq map-f(C, X X*-REST) = ⟦e⟧[x := X] map-f(C, X*-REST) .
```

`C` holds the variables that the body uses from outside the iteration. They
are found before translation (`prescan.ml:capture_variables`). For `^n`, the
helper also takes the count `n`, and an index argument that starts at `0` if
the iteration names an index variable.

| Helper | Name | Code |
| --- | --- | --- |
| `IterE`: compute the sequence | `map-f` if the body calls `$f`, `map-C` if it is constructor `C`, else `map-` and the enclosing definition or rule | `iter_helpers.ml:translate_statements` |
| `IterE` used as a pattern: recover the sequence of each variable | `unzip-C`, `unzip-` and the enclosing definition or rule otherwise | `iter_helpers.ml:translate_projector_statements` |
| `IterPr`: check every element | `all-` and the enclosing definition or rule | `iter_helpers.ml:translate_premise_statements` |
| `IterPr`: compute one unbound generator sequence | `bind-` and the enclosing rule | `iter_helpers.ml:translate_premise_statements` |
| Membership choice (section 2) | `choose-f` | `decd.ml:choice_helper` |

A helper is generated only if a translated term or condition calls it. The
call is recorded in a request table (`prescan.ml:request`) by the function
that emits the call (`iter.ml:request_helper`,
`iter.ml:premise_helper_call`) or by
`prem.ml:translate_barrier` for an `IterPr` output. An `IterE` is identified
by its AST node, so the name lookup compares nodes physically. After all
definitions are translated, the requested helpers are generated
(`iter_helpers.ml:generate_requested`). Because a helper body can call another
helper, generation repeats until no visited helper receives a new request.
Requests for `IterPr` outputs come only from relation rules, which are all
translated before generation starts. An `IterPr` that
computes an unbound sequence is supported only in relation rules
(`collect_outputs` in `prem.ml:translate_all`).

Each iteration first gets its own helper under a unique working name. After
translation, helpers whose statements are equal up to variable names are
shared: the later ones are dropped and their calls go to the first. Sharing a
helper can make its callers equal, so this repeats until nothing changes.
Each remaining helper then gets its name from the table above. If several
different helpers would get the same `map-f`, `map-C`, or `unzip-C` name, each
of them is named after its enclosing definition or rule instead (e.g.
`map-ivrelop-ieq` and `map-ivrelop-ine`, both of which iterate `$extend__`),
and if that is shared too, after both (e.g. `map-rollrt-subst-subtype` and
`map-rollrt-IDX`). A name that is still taken gets the suffix `-2`, and so on
(`def.ml:share_helpers`).
A helper in a rule is named after the relation and the rule (e.g. `map-Step-read-vload-pack-val`).
A shared helper named after an enclosing definition or rule keeps the name of
its first occurrence.

## 7. Steps outside the recursive translation

| Step | Purpose | Code |
| --- | --- | --- |
| Before translation | Remove the premises named by `hint(maude_assume)`, and the quantifiers whose variables occurred only in those premises | `def.ml:assume_script` |
| Before translation | Remove `DefP`/`DefA` (section 5) | `def.ml:specialize_script` |
| Before translation | After a premise `e = {.., f x*}` on a `hint(maude_array)` or `hint(maude_map)` field `f`, write `e.f` for `x*` in the later premises and the result, so that `x*` gets the stored translation (section 4). Only clauses and rules with such a premise are rewritten. | `def.ml:stored_script` |
| Before translation | Replace an operation on literals (`BinE`, `UnE`, `CvtE`, `CmpE` on numbers or booleans) by its value when it is defined (`Xl.Num`, `Xl.Bool`), innermost first; an undefined operation such as `1 \ 0`, or one with a non-literal operand, is kept | `def.ml:fold_ground`, `def.ml:fold_script` |
| Before translation | Case premises (`Step_exp/INJ`): for each evaluated `Unchecked` `CaseE C e` (all its variables bound by earlier premises or inputs), add the premises of case `C` instantiated with `e` before the premise that evaluates it, or after the premises for a rule output or clause result; inside an iteration, as an `IterPr` over the bound sources. Instantiated premises are folded as above and omitted when they fold to `true`. Relation inputs, clause arguments, and constructions with unbound variables are patterns and get none. The added premises (and those for results) are recorded in the index; clauses that got some are partial. | `def.ml:case_premise_script`, `prescan.ml:is_case_premise`, `prescan.ml:is_partial_def` |
| Before translation | Choose Maude names; collect variables, iterations, relation kinds, and hints | `prescan.ml:scan` |
| Type guards | A variable of a quantifier or parameter gets a condition `typecheck(X, ⟦t⟧)`, unless its type is already established: by a premise that binds it from a relation call, or by the declared types of the rule's inputs, or by an argument `SubE` pattern of a function head that already checks an equal membership. In a syntax instance such as `syntax num_(Inn)`, the `SubE` check of the alias-expanded type (`addrtype`) keeps its place but uses the quantifier's type (`Inn`), and the quantifier check is not repeated; the type is replaced in the source
pattern before translation. A variable of a `hint(maude_sort)` type keeps its
guard: the sort's constructors are wider than the type (`CONST(I32, c)` has
sort `val` for any `c`). In every context, including syntax membership equations, a variable of Maude sort `Nat` (`Int`) gets no guard for `nat` (`int`) or an alias of it (e.g. `syntax N = nat`, `syntax exp = int`): the sort already ranges exactly over those values. A guard of an earlier rule's `r̂-r-enabled` predicate is also dropped when every caller already checks it. This assumes that relation calls and inputs only produce values of their declared types. | `param.ml:translate_eq_conditions` (`proven`), `term.ml:translate_typ_conditions`, `term.ml:with_relation_types`, `term.ml:translate_guard_conditions`, `reld.ml:helper_statements` |
| Condition order | Place each condition after the conditions that bind its variables. Among ready conditions, relation rules take equational conditions before rewrite conditions, and function clauses take conditions that bind nothing before conditions that bind variables. Otherwise the order of the premises is kept. | `maude_il.ml:schedule_conditions`, `maude_il.ml:schedule_rule_conditions`, `maude_il.ml:schedule_equation_conditions` |
| Condition order, execution rules | The `typecheck` guards of the rule's inputs come first | `maude_il.ml:schedule_execution_conditions` |
| After translation | Remove repeated conditions, including an equality that repeats an earlier match or equality in either order | `maude_il.ml:simplify_conditions` |
| After translation | Declare variables and put declarations first | `def.ml:normalize_module` |
| Sequence support | List sorts selected by `hint(maude_sort)`, subsorts of the prelude `LIST{SpectecTerminal}` with `nil`/`__` overloads | `typd.ml:Lists` |

### Hints read by the translator

| Hint | Where | Section |
| --- | --- | --- |
| `builtin`, `maude_kind`, `maude_rule`, `inverse` | `DecD` | 1, 3 |
| `maude_map` | `DecD` | 4 |
| `maude_compute`, `maude_check` | `RelD` | 2 |
| `maude_subsume`, `maude_trans`, `k_heatcool` | `RuleD` | 2 |
| `maude_assume` | `RuleD` and `DecD` | 7 |
| `maude_sort`, `maude_subsort`, `maude_proper` | `TypD` | 7 |
| `maude_array`, `maude_map` | a field of `StructT` (the hint list of the field) | 4 |

Hints arrive as `HintD` definitions (`TypH`, `RelH`, `DecH`, `RuleH`) and
are collected by `prescan.ml:collect_hints`. A field hint (`maude_array`,
`maude_map`) stays in the hint list of its `StructT` field and is read by
`hintd.ml:stored_of`. Other hints (for example, the documentation hints
`name`, `macro`, and `tabular`, and every `GramH`) are ignored.

## 8. Cases that are rejected or omitted

A rejected case stops the translation with an error at the source location of
the rule, clause, or iteration, naming the definition and the reason. An omitted case produces no Maude output.

| Case | Behavior | Code |
| --- | --- | --- |
| A relation whose kind is none of section 2 (for example, a validation relation without `maude_compute` or `maude_check`) | omitted; listed in a warning with the reason; a premise that uses it is rejected | `def.ml:translate_script`, `reld.ml:translate` |
| A function with a clause that uses an omitted relation | declaration only; a call to it is rejected | `prescan.ml:unsupported_definitions`, `term.ml:translate_value` |
| `TheE`, `UncaseE` with a named constructor | rejected | `term.ml:translate_value` |
| `BinE` nat subtraction or nat/int division (partial in the IL, total in Maude) | rejected | `term.ml:translate_binop` |
| An evaluated `SubE` into a variant whose shared cases have premises or into a record with field premises, an evaluated field update through such a record, an evaluated `StrE` of a record with field premises, a case quantifier inside an iteration, or a case type that does not reduce to a definition | rejected (the rechecked or field premises are not instantiated) | `def.ml:recheck`, `def.ml:case_premises`, `def.ml:iterexp_case_premises` |
| A complement of an earlier function clause or rule that has a case premise inside a premise | rejected | `decd.ml:ordered_clauses`, `reld.ml:lower_execution_rule` |
| `CvtE` to or from `real` | rejected | `term.ml:native_exp` |
| `SubE` between types with different Maude representations | rejected | `term.ml:translate_value` |
| `IdxE`, `SliceE`, and the paths `IdxP`, `SliceP` on a sequence with its own sort (`hint(maude_sort)`) | rejected | `term.ml:translate_value`, `term.ml:translate_select` |
| `IterT t +` and `IterT t ^n` as a type argument | rejected | `term.ml:translate_check_typ` |
| `hint(maude_array)` or `hint(maude_map)` on a field that is not a sequence, or of a record type with parameters; both on one field; either on a `syntax` declaration instead of a field | rejected | `hintd.ml:stored_field_of`, `hintd.ml:stored_of` |
| A `maude_array` field read other than by `LenE`, `IdxE`, `SliceE`; written by `IdxP` or `ExtE`; selected inside; or `CompE` of its record | rejected | `term.ml:translate_value`, `term.ml:translate_select`, `term.ml:translate_update`, `term.ml:translate_extension`, `term.ml:translate_composition` |
| A `maude_map` field or `hint(maude_map)` call read other than by `LenE`, `IdxE`; written by `SliceP` or `ExtE`; selected inside by `SliceP`; a `hint(maude_map)` `DecD` clause that does not return a `maude_map` field | rejected | `term.ml:translate_value`, `term.ml:translate_select`, `term.ml:translate_update`, `term.ml:translate_extension`, `decd.ml:translate_result` |
| `ElsePr` in a `maude_rule` function, or not as the first premise of an execution rule | rejected | `decd.ml:translate_rule_clause`, `reld.ml:lower_execution_rule` |
| An `ElsePr` execution rule with no earlier rule | rejected | `reld.ml:lower_execution_rule` |
| `ElsePr` in a rule of a computed or checked relation, in the premises of a type, or in an `IterPr` body | rejected | `reld.ml:translate_rule`, `prem.ml:translate_eq_conditions`, `iter_helpers.ml:premise_conditions` |
| `ElsePr` or `IterPr` in a `k_heatcool` split rule, split rules whose shape does not fit section 2, and a rewrite condition in a split equation | rejected | `hintd.ml:scan_heatcool`, `hintd.ml:scan_contexts`, `heatcool.ml` |
| A `k_heatcool` context rule with a context that changes when its inside steps, a conclusion input that is not one sequence element, no sequence context or nonempty condition in its relation, or no rule consuming its element | rejected | `hintd.ml:scan_kembedding`, `heatcool.ml:kept_rule`, `heatcool.ml:kembedding_rule`, `heatcool.ml:kembedding_statements`, `heatcool.ml:translate_relation` |
| An `ElsePr` execution rule whose earlier rule needs an `r̂-r-enabled` predicate but has a rewrite condition | rejected | `reld.ml:helper_conditions` |
| A call of a `maude_rule` function from a function without `maude_rule`, or in an argument or result of a `maude_rule` clause | rejected | `decd.ml:equation_clause`, `decd.ml:translate_rule_clause` |
| `ElsePr` or a `maude_rule` call in the premises before a membership choice | rejected | `decd.ml:translate_choice_clause` |
| A function clause after an earlier clause that overlaps it without one head being an instance of the other, whose extra head structure is not ground, or whose conditions bind variables | rejected | `decd.ml:complement` |
| A record field whose type is a tuple (`syntax r = {A nat, B (nat, nat)}`) | rejected | `typd.ml:translate_struct_field` |
| An alias of `t?`, `t+`, or `t^n` as a type value (`syntax foo = nat?`); as a type argument `t?` is supported, and `t*` is its element type here but `iterList` there | rejected | `term.ml:translate_typ` |
| `IterE` with `?`, `*`, or `+` and no generator | rejected | `iter.ml:translate_term` |
| `IterPr` with an unbound captured variable or count, with several unbound sources, or with one unbound source under `?`, `*`, or `+` and a single generator | rejected | `prem.ml:translate_barrier` |
| `CompE` on a record type with type parameters, or on a type that is neither a record, an option, nor a sequence | rejected | `term.ml:translate_composition` |
| `GramD`, `ProdD`, grammar symbols (`VarG` … `AttrG`), `GramP`, `GramA` | not translated | `def.ml:translate` |
