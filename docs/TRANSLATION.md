# Translation meaning, source hints, and supported scope

The translation target is the whole IL AST obtained by elaborating the
specification files of the [fixed revision](../spectec/REVISION): the 21
`wasm-3.0/*.spectec` files, and the 9 files of each of `wasm-1.0/` and
`wasm-2.0/` (chapters 0 to 9; the binary format, a grammar, is not translated).
The same translator, with the same hint contracts, translates the three
versions; their builtins are in `translator/builtins/` (core and vector parts
shared, one `wasm-VERSION.maude` per version). The translator recursively translates the type declarations, function bodies, rules, and premises of that input
without hardcoding names. It does not delete part of the input IL because a particular Wasm program or test
does not execute it.

Supporting every arbitrary SpecTec specification of any form definable in `ast.ml` is
not a current goal. Backend cleanup must preserve the representations and operations needed to
translate and compute the input IL. A fact that a test did not call something is not by itself a reason to judge it unused.
The declarations, function bodies, and rules of the source are not modified; only explicit translation hints are allowed.

## AST and reference documents

- Actual input structure: [lib/il/ast.ml](../spectec/lib/il/ast.ml).
- Meaning of the IL (formal): [doc/semantics/il/][formal] of the same revision
  (`Step_exp` in `5-reduction.spectec`, etc.). It is **the specification of the IL itself** written in SpecTec,
  not a file of Wasm execution rules.
- Language description: [Language.md][language] of the same revision. Where it differs from the formal, this is noted below.

The semantic reference of the translation is the IL AST and the reduction rules of the formal. The translator does not guess
meaning from AST constructor names alone, and it uses the behavior of the evaluator (`il/eval.ml`) or the interpreter only as supporting evidence.

## Value construction and type constraints

The IL marks for each constructor value whether it is checked (`CaseE (op, e, check)`, `StrE (fs, check)`,
`Checked | Unchecked`). When the formal `Step_exp/INJ` computes an `Unchecked` construction `C e`, it
checks the premise of case `C` on the payload, and if it is false the computation fails (there is no rule
that moves on to the next clause or rule, so it is stuck). The translation follows this meaning
(`def.ml:case_premise_script`, at the IL stage before translation).

- For each computed construction (a construction whose variables are all bound earlier), the case premise is
  instantiated with the payload and inserted before the premise that computes that construction, or after the premises if it is a result or rule output.
  A construction inside an iteration is inserted as an `IterPr` of the same iteration, and an element variable is treated as bound only when its source
  is bound. Example: `L-1` of `br` gets
  `_and_((L-1) >= 0, (L-1) <= 4294967295)`.
- A construction that is a relation input, a function argument, or that has an unbound variable is a pattern. In the formal too
  it only matches an existing value and is not checked (`Step_expmatch/INJ-good`). Of the values that come from outside the IL,
  the initial state of `wasm2maude` is built from a module that passed the validator of the official interpreter (`Valid.check_module`),
  and that encoding and the `hint(builtin)` implementations are checked with the official tests.
- A function that contains a check may have no result, so it is declared with `~>`
  (`Prescan.partial_defs`, the same effect as `hint(maude_kind)`).
- If the check of a result or output fails, the failure happens after that clause or rule has already been selected, so it is stuck. Therefore
  the complement of a later clause and the complement of an `ElsePr` rule leave that check out and negate only the original premises,
  and if such an earlier clause overlaps, `[owise]` is not used either. When a construction check inside a premise
  fails, it must also be stuck, but the negation of the premise is then true. So an `ElsePr` rule after such a rule also
  requires those checks, stated on its own inputs (`reld.ml:lower_execution_rule`, Wasm 2.0 `vtestop-false`): with them,
  its complement holds exactly when the earlier rule's other premises fail. Checks that need variables the inputs do
  not bind, and such an earlier DecD clause, are rejected (`Unsupported`).
- `SubE` checks the premises of the target case again (`SUB-INJ`). When the source and target cases have the same
  payload type, quantifiers, and premises (Wasm 1.0/2.0 `instr <: admininstr`, where `admininstr` includes `instr`),
  a source value already satisfies them and nothing is added. Other rechecked `SubE` premises and those of field update
  (`SUB-STR`, `UPD-DOT`), and `StrE` with field premises, are not instantiated and are rejected (`Unsupported`).
- Number and logic operations without variables are replaced by values before translation (`def.ml:fold_ground`,
  `Xl.Num`/`Xl.Bool`). They are replaced only when both operands are literals and the operation is defined;
  `1 \ 0` or `0 * e` (computing e may fail) are left as they are. The same function is used for constant expressions produced by
  instantiation, and a check that became `true` is omitted. Example: `2^32 - 1` →
  `4294967295`, and the `0 <= 0 <= 255` check of a memory byte is omitted.

SpecTec [Language.md][type-premises] describes premises as "invariants not checked when a value is constructed",
and the interpreter (AL) does not check them either. The formal IL and this description differ, and the translation follows
the formal IL. As a result, `$binop_(Inn, SHL/SHR, ..)` in the current source makes the shift amount
a `u32`, so it is stuck for amounts of 2^32 or more (`i64.shl` in `i64.wast`, etc.;
`Il.Eval` fails the same way). Even under Language.md, the source constructs a value that violates its own type invariant,
so this is recorded as a problem on the source side.

## Current implementation and unsupported items

- A general list is the prelude `LIST{SpectecTerminal}` (sort `SpectecTerminals`, `nil`, `__`), and
  a list used as a list element is distinguished by `seq(...)`. A separate list sort is selected only by the `maude_sort` hint.
- The Nat, Int, and finite Rat computations and conversions used by the Wasm IL are kept.
  Wasm f32/f64 are handled by the source's `POS/NEG`, `NORM/SUBNORM/INF/NAN` data and builtins.
- IL Real values, conversions, and arithmetic, non-finite Rat values, and some Rat arithmetic, which are not in the current input,
  are not supported. If such input is added, it is explicitly rejected; handling it requires
  reviewing the corresponding AST translation together with the backend meaning.
- The replacement return of a root `UpdE` is kept. `RootP` is also needed to end the recursion of nested updates.
  The IL of the current revision has no `IfE` or `NegPr`.
- An argument or result whose type is fixed by a type parameter (`def $relaxed2(.., syntax X, X, X) : X`)
  is a single value even if X is a list type, so if it is a list it is passed wrapped in `seq(...)` and the result is
  taken out with `unseq` (`term.ml:syntax_parameter_positions`).
- IL nat subtraction and nat/int division are partial operations, and Maude `_-_`, `_/_` produce negative numbers and fractions,
  so if they appear as is they are rejected (`Unsupported`). In the current source, elaboration converts them to int/rat
  before computing.
- A call of an undefined function (a stuck term) remains an uncomputed term in Maude. When this term
  enters a `==`/`=/=` comparison, a complement of the form `b =/= true`, or `[owise]`, it may become a value or the next clause
  instead of being stuck as in the IL (e.g. `-- if $f(n) =/= 2` when only `$f(0) = 1` exists).
  The same holds for partial functions declared with `->`. Whether such calls arise in normal Wasm execution
  was not confirmed, and this remains a known limitation (resolving it is separate work that needs partial function declarations and value-check
  conditions).
- `TheE`, which is not in the current input, and the type value representation of `List1` and `ListN`, which the current translation does not use,
  are not supported. The corresponding backend operations `_!`, `iterList1`,
  `iterListN` are not provided, and an attempt to translate such a form is rejected (`Unsupported`).
  The `ListN` iteration and length check used by the actual input are kept. When extending the input scope,
  add the needed AST translation and backend operations together.
- Generating concrete instances of polymorphic records and generating nested SubE adapters that change the representation are
  not currently provided. Record composition is translated following the field types of the parameterless StructT declaration.
  The type check directly matches the whole record in declaration order, and no general check that allows reordering or adding
  fields of an arbitrary record is generated.
  Actual SubE in Wasm keeps the existing representation. As in the baseline commit, `same_representation` is checked at each `SubE`.
  No separate whole scan for nested conversion is kept.
- In a relation premise, if a variable i that is not bound by any input is used only as the index of a known `xs[i]`,
  i chooses a valid position of xs (`xs[i]` is defined only when i < |xs|):
  `PREFIX E SUFFIX := xs /\ I := |PREFIX|`. Example: `typeuse*[i]` of `Deftype_sub/super`.
  If a conclusion input of a `maude_check` rule is not a pattern (e.g. `typeuse*[j]` of `Heaptype_sub/rec-sub`),
  it is compared with that value after the premises bind the variables.
  An `e?{}` pattern without a constructor is equal to eps or e (e.g. `NULL?` of `Reftype_sub/null`).
- Function arguments (`DefP`/`DefA`) are specialized into per-function definitions before translation
  (`Def.specialize_script`, `Decd.specialize`). For each call `$g(..., def $t, ...)`, a copy `$gt`
  of `$g` is made and the def parameter name in the body is replaced by `$t` (source meaning
  `$g_t(xs) = $g(xs)`, f := t). A higher-order definition that is not called is not output.
  Passing a received function on again (including recursion that passes the same function), a def parameter that takes
  a def parameter, `DefA` outside a DecD call, `DefP` of TypD/RelD/GramD, the
  `builtin`/`maude_kind`/`maude_rule`/`inverse` hints of a higher-order definition, and copy name collisions are
  rejected (`Unsupported`).
- Function clauses are matched in order from the top (SpecTec paper, `reduce_exp_call` in `eval.ml`).
  Maude equations have no order, so a clause that may overlap an earlier clause gets the condition that the earlier clause
  does not match (`decd.ml:complement`). Example: `ceq inv-jsize(N) = inv-isize(N) if N =/= 8
  /\ N =/= 16`. Overlap is decided from the source pattern and the translated head, and types whose constructors do not overlap
  (`Inn`, `Fnn`) do not overlap. If neither of the two heads is an instance of the other,
  or the earlier clause's condition binds variables, it is `Unsupported`, except for the last clause: when a complement
  cannot be stated for it (for example an earlier head with non-ground extra structure, Wasm 2.0
  `$dataidx_instr(MEMORY.INIT x)` before `$dataidx_instr(in)`), it is `[owise]`, which applies exactly when no earlier
  clause does, provided no earlier overlapping clause has case premises; otherwise it is `Unsupported`. One difference
  remains: if an earlier clause's condition is stuck (neither true nor false), the IL keeps the call stuck
  (`Step_exp/MATCH-false` needs `false`), but `[owise]` applies. This is the same as the complement `_=/=_` of two stuck
  terms; the Wasm 1.0–3.0 output has no such clause (its only new `[owise]` follows unconditional clauses).
  A negation already implied by the clause's own condition may be added (`$signed_`): it is redundant but not wrong.
  An `ElsePr` clause is `[owise]` and must be the last clause (not checked).
- The typecheck of a list alias (`resulttype = valtype*`, `expr = instr*`) is per element. A wrapped
  `seq(v)` is one alias value, and the direct equation applies only to one unwrapped element
  (`V =/= seq(unseq(V))`). Multiple elements are checked by the backend's per-element equation. The three equations
  do not give different results on any term.
- Unsupported forms of the `#` representation: within one family, if the arguments of the same constructor differ by instance in whether they are
  native, it is rejected. A `hint(inverse ...)` of another def that targets a higher-order definition is
  not checked. Concatenation of text values is translated as list concatenation and is not in the current input.
  The wasm2maude encoder decides the `#` positions directly from the Wasm structure, so if the semantics'
  sorts change, it must be fixed together.
- Unsupported branches remain for AST forms and hint combinations beyond the current input.
  Passing the Wasm specification translation and execution tests is not extended to translation support for arbitrary SpecTec specifications.

## Limits of verification and model checking

Installation and usage are in [ARTIFACT.md](ARTIFACT.md). Hint contracts are
recorded below. PASS, STUCK, and TIMEOUT are distinguished.
Passing the official suite alone does not prove semantic equivalence for all programs.

The initialization and execution wrappers of the model checker and the focus/split/plug intermediate states are not
identified with one source step. To claim a particular property transferred to the source, the state correspondence, observation points,
the effect of divergence and deadlock in internal steps, and whether the search completed must be checked separately.
No equivalence with the whole current checked formal or completed preservation proof is claimed.

### Import scope (decision, 2026-10-03)

`run`, `modelcheck`, `instantiate`, and `harness` reject a module with imports as
Unsupported (`wasm2maude/emit.ml`). In result accounting it is also counted as Unsupported, not PASS.
`$instantiate` is `maude_assume "Module_ok" "Externaddr_ok"`.

- Reason: executing or model checking a program with imports requires a side that provides the imports.
  For example, the body of `(import "env" "print" (func (param i32)))` is in the host
  and not in the SpecTec specification. Two things are needed: (1) a provider (another Wasm module or a host function
  model) and (2) the type check of what is provided (`Externaddr_ok`). Without (1), translating only (2)
  still does not allow execution, so import support is separate work done together with (1).
- Without imports, omitting the two premises of `$instantiate` leaves the meaning unchanged.
  The `xt_I*` produced by `Module_ok` is empty and `externaddr*` is also `eps`, so
  `(Externaddr_ok: s |- externaddr : xt_I)*` is an empty iteration. This equivalence holds
  only when there are no imports, so the rejection in wasm2maude guarantees that precondition.
  The type check of `Module_ok` is assumed to be guaranteed by the frontend validator.
- When imports are supported later: if the frontend (the linker of the reference interpreter) checks import types
  at the link stage, `Externaddr_ok` can also be kept as an assumption by the same logic as `Module_ok`.
  Then the validation relations under `Externtype_sub` need not be
  translated. In that case, record the assumption that the frontend check and the specification relation are the same.
- The wast harness already works this way. At the planning stage, `Wasm.Match.match_externtype` of the reference interpreter
  checks import types (`wasm2maude/wast_plan.ml`),
  and only the current minimum size condition of memory/table is checked at run time by Maude's `linkImports`
  (`wasm2maude/wast-runtime-core.maude`). Therefore import modules in wast are supported under the assumption that the frontend linker
  makes the same judgment as `Externaddr_ok`.

### Invocation argument check

`(Val_ok: s |- val : t_1)*` of `$invoke` checks the number and types of the arguments. wasm2maude
only checks that the export is a function. If `Val_ok` fails, `$invoke` is undefined,
and the `run`/`modelcheck` runtime ends in the `invalid-invocation` state. In this state
no value is returned, so a safety query such as `[]~ returned(rejected)` is vacuously
true. First check that the `rewrite` result is not `invalid-invocation`.

## Common backend and list computation

The entry point of the common backend is `translator/backend/spectec-semantics.maude`.
First, `SPECTEC-SORTS` in `spectec-sorts.maude` declares the common sorts,
then `generated/types.maude` is loaded, and `SPECTEC-BUILTIN-TYPES` in `spectec-builtin-types.maude`
declares the Maude representation of the SpecTec base types (`bool nat int rat real text`),
that is, native imports, type tags, and basic checks. This representation is a representation choice, not the meaning of IL
operations, so it is kept in a file separate from the semantic modules.

Base types are wrapped in a constructor as in IMP (`op #_ : Bool|Rat|Float|String ->
SpectecTerminal [ctor]`). Native sorts are not made subsorts of `SpectecTerminal`, so
prelude operations with the same name do not clash in one kind and no import renaming is needed.
IL `nat`/`int` values are represented as native `Nat`/`Int`, and other values as `SpectecTerminal`.
The translator inserts or removes `#` only when the sort of a value differs from the sort its position expects
(`Iter.coerce`): when a native value goes into a list, option, or tuple element, a constructor or def argument, a record field,
or a `typecheck` target, it becomes `# V`; when it is taken out, a pattern matches `# V`, and in the middle of an expression the
partial functions `#rat`/`#bool`/`#string` are used. Results of comparison and logic operations are native, so they are
wrapped in value positions, and arithmetic and comparison operands are taken out as native. CvtE takes and returns native `Rat`.
Constructor argument sorts come from the declaration of the variant type that the `CaseE` belongs to,
and def call result sorts come from the result sort declared by the callee.

Operations by feature are in the following modules in the file `spectec-semantics.maude`.

| Module | Contents |
|---|---|
| `SPECTEC-CONVERT` | numeric type conversion |
| `SPECTEC-LIST` | list representation, checks, operations |
| `SPECTEC-OPTION` | option representation, checks, operations |
| `SPECTEC-TUPLE` | tuple representation, projection |
| `SPECTEC-RECORD` | record representation, lookup, update |
| `SPECTEC-ARRAY` | size of `hint(maude_array)` fields + prelude `ARRAY` representation and operations |
| `SPECTEC-MAP` | size of `hint(maude_map)` fields + prelude `MAP` representation and operations |

convert and list import builtin types, and option, tuple, record, array, and map import list.
The final `SPECTEC-SEMANTICS` collects the seven modules. The common list is
the prelude `LIST{SpectecTerminal}` imported by `spectec-sorts.maude` with only the sort names changed
(`nil`, `__`, `size`, `occurs`, `append` keep their prelude names).
`SPEC2MAUDE-TYPES` in `types.maude` places the per-hint list sorts on this list as subsorts
and overloads only `nil`, `__` at the narrower sorts (it does not instantiate LIST again).
`generated/output.maude` imports `SPECTEC-SEMANTICS` and adds the translated
definitions.

There is one LIST instance, so `nil`, `__`, `size`, `occurs` of typed lists are all the same
prelude operations, and it loads without warnings or advisories. Prelude operation names (`nil`,
`size`, `occurs`, etc.) are in `Prescan.reserved_names`, so a source
definition with the same name gets the `spectec-` prefix (e.g. Wasm `$size` → `spectec-size`).

Nonempty lists are distinguished by the sort `SpectecNeTerminals`, as in the prelude `LIST`
(`SpectecTerminal < SpectecNeTerminals < SpectecTerminals`). The shared list check
`typecheck(T NTS, TYPE)` recurses only when there are two or more elements, and since the empty list is a
valid value of `t*`, `typecheck(nil, TYPE) = true` is kept. For each typed list root,
`NeXList < SpectecNeTerminals` is generated as well. The current Wasm `val < instr` lists share `nil` and `__`.
No path that generates a separate concatenation operation is provided, and a hint combination in which the list sorts do not form one
subsort chain is rejected (`Unsupported`).

`typecheck` checks values and lists that belong to `SpectecTerminals`. The failure
equations are also defined with sort variables. An option type `t?` is checked with `iterOpt(t)`,
and its value is `nil` or `V ?` wrapping one value of `t`. Undefined terms that belong only to the kind are
not uniformly turned into `false`, and the check expression of such a term may remain
uncomputed. A generated positive check condition holds only when it is `true`, so an uncomputed check does not
pass either. When extending this to negate the check result itself or compare it with `false`,
a separate contract for handling undefined terms must be set.

The IL translation of `LenE`, `SliceE`, `UpdE` and premises/iterations is kept.
`ListE` uses list concatenation directly and `LenE` uses the prelude `size` directly, so
no separate `[TS]`, `|TS|` notation wrappers are provided.
Membership (`MemE`) uses the prelude `occurs`.
Index, slice, element update, and range update are defined by structural recursion that removes leading elements one at a time, like the prelude `occurs`
(`(T TS)[(s N)] = TS[N]`, `(T TS)[(s N) = K] = T TS[N = K]`).
Slice/splice skip to the start position and then take or drop `COUNT` elements. Therefore
the domain is `N + COUNT <= size(S)`, and an empty slice is allowed up to the end position. Out of range,
no equation applies, so it is undefined. `seq(...)` is one element.
Update and the take part of slice are not tail recursive, so they use stack proportional to the position (count)
(confirmed up to about 260,000 cells with a 64MB stack; overflow at 520,000 cells).

Length is computed with the prelude `size`/`$size` (accumulator).
Repeated lists are built by the direct recursive equations `repeatSeq(0, S) = nil`,
`repeatSeq(s N, S) = S repeatSeq(N, S)`.
Typed lists declare no separate operations and use the prelude operations as they are.

Record lookup/update (`_._`, `_[._=_]`, partial operations) match the field entry with the same name.
A well-typed record has only one entry per name. Lookup or update of a missing field
has no equation, so it is undefined as in the IL.

If `hint(maude_array)` is attached to a sequence field F of a record type
(`{.., F t* hint(maude_array)}`), F is stored not as a list but as `sized-array(size, A)`.
A is the prelude `ARRAY{Nat, Zero}`, and the view `Zero` sets the default value to `# 0`,
so cells that are 0 are not stored (the prelude `insert` removes 0, and `_[_]` returns 0 for a missing
cell). Since the size is kept separately, the length check is not proportional to the number of cells.
The operations are in `SPECTEC-ARRAY`.

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

`array-read`, `array-write` are defined only for `i + n <= size`, like list slice/splice.
`array-of` turns a list into an array. The value of another array field is used as is, without conversion.
A field pattern (`-- if e = {.., F b*}`) binds the array value as is, and before translation
(`def.ml:stored_script`) `b*` is rewritten to `e.F` in the following premises and the result.
In the source `b* = e.F`, so the meaning is the same, and `|b*|` and `b* 0^n` get the array translation of the table above
(Wasm `$growmem`).

Uses outside the table above (reading the field value itself as a list, updating one element, extending with `++`, `CompE` of a record
that has the field) are rejected (`Unsupported`). No `recordConcat` equation is generated for this record type.

A field F with `hint(maude_map)` is stored as `sized-map(size, M)`. M is the prelude
`MAP{Nat, Terminal}` (with the entry operator renamed to `_|=>_` so as not to overlap with ARRAY), and every index from 0 to
size-1 has exactly one entry. There is no default value, so the element type need not contain 0.
So `map-read`·`map-write` directly match the entry with the same key. The prelude `M[I]`·`insert` are not used, because they
search for duplicate entries of the same key every time. A read or write of a missing index has no equation, so,
as in the source, there is no value.
A function `def $f(..) : t* hint(maude_map)` means that its result is such a field, and the calls `$f(..)[i]`,
`|$f(..)|` are translated to map operations. Each clause of the function must return a maude_map field.

| source | Maude |
|---|---|
| `\|e.F\|`, `\|$f(..)\|` | `map-size(e . 'F)`, `map-size(f(..))` |
| `e.F[i]`, `$f(..)[i]` | `map-read(e . 'F, i)`, `map-read(f(..), i)` |
| `e[.F[i] = x]` | `e[. 'F = map-write(e . 'F, i, x)]` |
| `e[.F[i].G.. = x]` | modify `map-read(e . 'F, i)`, then put it back with `map-write` |
| `e[.F = s]` | `e[. 'F = map-of(s)]` |
| `e[.F[i : n] = s]` | `e[. 'F = map-write-range(e . 'F, i, n, s)]` |
| `e[.F =++ s]` | `e[. 'F = map-append(e . 'F, s)]` |
| `{.., F e.F' s}` (e.F' is a map field) | `map-append(e . 'F', s)` |
| `{.., F s}` | `map-of(s)` |
| record `r ++ r'` | for this field, `map-concat(r . 'F, r' . 'F)` |

`map-write` is defined only for `i < size`, like list update. `map-concat` shifts the right entries
by the left size. The result is the same regardless of the order of shifting. Uses outside the table above (reading the field or call
value itself as a list, range read) are rejected (`Unsupported`). `map-write-range` writes the n elements of s one by
one with `map-write`, so it is defined only for `i + n <= size`, like the list range update.

The nondeterministic membership choice helper selects a possible element with a prefix/selected element/suffix matching rule.
It keeps the source choice meaning, boxing, and frozen arguments.
Bitwise logic operations use native Nat operations that keep the width/operand conditions.
CLZ/CTZ and fixed-size chunks are implemented by matching, and the recursive computations that build the actual result,
such as encoding, accumulation, and reversal, remain.

Popcount and bit reverse are also computed with accumulator equations.
Their invariants are `count + number of 1s in the remaining bits` and `reverse(remaining bits) accumulator`,
respectively.

This correspondence concerns the results and domains for finite ground canonical source values.
`[owise]` membership/record may give results different from the earlier unevaluated term on an unknown symbolic tail,
so narrowing equivalence for free list variables is not claimed.
It is not extended to a preservation proof for source rules, the IL iteration meaning, or the whole model-checking graph.

## Lookup and result checks in the Wasm driver

`findFunc` of run/modelcheck and `findExport` of WAST match before/after an export.
The condition that the prefix has no entry with the same name keeps the existing meaning of selecting the first export.
In particular, it does not skip an earlier global with the same name to select a later function.
For a missing export or a wrong address kind, no normal lookup result is added.

The WAST instance environment is represented with `instances.entry` and associative `instances.concat`.
The identity is `instances.nil`, and `comm` is not attached.
Mapping `cons(k,v,rest)` to `entry(k,v) concat encode(rest)` preserves the existing order and
insertion position. `findInstance` also selects the first identical ID with a prefix condition.
Environment construction in host-provider and module-done uses the same representation.

`match.any` finds one pattern that succeeds among associative alternatives.
For the supported canonical results/patterns, it is the same existence condition as the existing Boolean OR,
and `match.no [owise]` applies only when no pattern succeeds.
`activeFrameDepth` skips the value prefix confirmed by `runtimeResults` and then descends only into the body of the active
FRAME/LABEL/HANDLER. A FRAME of a later sibling is not counted.
`runtimeResults`, positionwise comparison of arguments/results, and construction of the import list are operations that
check all elements or build a result, so the needed structural recursion is kept.

The evidence is §4.3 (conditions and matching), §4.4 (operator attributes), §4.5.4 (owise),
§8.3 (native NAT), §8.14.1 (LIST) of the [Maude 3.5.1 manual](../reference/manual/Maude3.5.1-manual.pdf),
and the LIST/NAT definitions in the installed 3.5.1 prelude. The reason for not replacing it with native MAP is that it would change the
meaning of duplicate keys.

The WAST printer groups a long `Seq` into balanced parentheses to reduce Maude's cost of parsing flat associative
syntax. Each leaf group has at most 8 elements, and only the associativity of `__` is
used. Element order, the argument boundaries of `App`, and the boxing that distinguishes list elements are kept.

The WAST command list is built as one `commands.cons` list (empty input is `commands.nil`)
and put directly into the harness's `rew` start term `script.ready(emptyStore, environment, commands)`.
If it were defined by an equation, Maude would compile all equations of the module before rewriting,
and for a command list containing large modules this compilation is slow (skip-stack-guard-page: 8.8 s → 3.0 s).
The encoding and order of each command are unchanged, and the SpecTec execution rules and the general Wasm run/modelcheck
output are not changed.

WAST host memory (spectest `memory`) is built as `sized-array(size, empty)` because `BYTES` of `meminst` is a `maude_array`
field (`wast_host_encode.ml`). The memory and
data instances of a module are built by the translated `allocmem`/`allocdata`.

[language]: https://github.com/WebAssembly/spec/blob/e22ec2272bfbc06b995b00c1f1172a61d613fdd8/spectec/doc/Language.md
[type-premises]: https://github.com/WebAssembly/spec/blob/e22ec2272bfbc06b995b00c1f1172a61d613fdd8/spectec/doc/Language.md#premises
[formal]: https://github.com/WebAssembly/spec/blob/e22ec2272bfbc06b995b00c1f1172a61d613fdd8/spectec/doc/semantics/il/

## Source hints and handwritten implementations

The target is the [fixed Wasm source](../spectec/REVISION) and the hints attached to that source.
A hint makes explicit a boundary that is hard to translate directly; it is not permission to add a computation that is not in the source.

### Translation interface

| Hint | Role and applicability conditions |
| --- | --- |
| `maude_sort` | Gives a source type a separate Maude sort and list representation. The sorts used as lists must form one subsort chain. Without it, the general `SpectecTerminals` representation is used. |
| `maude_subsort "T"` | Subsort relation between the marked source types. A wrong target or a cycle is rejected. |
| `maude_proper "V P"` | Builds a proper sort P that excludes the value V from the declared constructor set. Instruction names are not hardcoded. |
| `maude_array` (record field) | Stores this sequence field of a monomorphic record type as a size + prelude `ARRAY` (default value 0). Field access is limited to length, element and range reads, and range and whole writes; construction is limited to `0^n`, `s 0^n`, and lists. Other uses are rejected. 0s in the elements are not stored, so the element type must contain the number 0. This condition is not checked (it holds for Wasm `byte`). |
| `maude_map` (record field, function) | Field: stores this sequence field of a monomorphic record type as a size + prelude `MAP` (an entry at every index). Field access is limited to length and element reads and element, range (`map-write-range`), and whole writes and extension `=++` (`map-append`); construction is limited to lists, `e.F s`, and record `++`. Function: the result is a maude_map field, and calls are used only for length and element reads. Other uses are rejected. |
| `k_heatcool` | Translates a rule with an execution premise by heating/cooling. A context rule whose only premise is one execution premise of the same relation keeps the context open in `kstate(R, K)` by K embedding (K book §5.4.6), and other rules are connected by split/plug (K book §5.4.5). For a `~>` relation, split and focus identification are equations; for a `~>*` relation, split is a rule. The applicability conditions and assumptions are in [scope](#k_heatcool-scope) below. |
| `maude_kind` | Declares the result of a function with the partial arrow `~>`. A general function without this hint is declared with `->`. A function that contains a case premise check is also `~>` ([value construction and type constraints](#value-construction-and-type-constraints)). |
| `maude_rule` | Translates a function that needs a rewrite premise to a request/rule. It keeps the source result and the possible branches. |
| `inverse $g` | Obtains a missing argument with the declared inverse function g and rechecks the pattern and the forward result. The argument order and signature are checked. |
| `builtin` | Generates the function declaration and connects it to the handwritten implementation in `translator/builtins/` (`wasm-VERSION.maude` on the shared `core.maude` and, for 2.0 and 3.0, `vector.maude`). |
| `maude_compute` | Translates the relation to a partial operation that computes the output after one plain `~~` or `:`. |
| `maude_check` | Translates the relation to a partial Bool check that takes all components. It is `true` if the relation holds, and has no result otherwise. |
| `maude_subsume` (rule) | This rule of a `maude_compute` relation is in check form. It becomes a separate Bool operation named after the rule (`Ref_ok/sub` → `Ref-ok-sub`), and a call whose output is also known calls this operation. Only a call whose output is unknown calls the compute operation. |
| `maude_trans "C" ...` (rule) | The transitivity rule `R(.., h1, h2) :- R(.., h1, x), R(.., x, h2)` of a `maude_check` relation. The intermediate x is chosen among the listed nullary constructors, and the first premise uses the `-step` operation that excludes this rule. |
| `maude_assume "R" ...` (rule/def) | The premises of the listed relations are not translated. This is an assumption that the input already satisfies those premises, and the justification is recorded in the scope below. If a listed relation is not in the premises, it is rejected. |

`show`, `macro`, `desc`, `name`, `prose`, `tabular` are for document presentation and do not
select an execution method. That a hint passes the format check and that a handwritten implementation is correct
are separate checks. Source functions and rules are not deleted because they are unused.

### Application in Wasm

- `inv_concat_` recovers `(j_1 j_2)*` of the actual vector source two elements at a time.
  `inv_concatn_` recovers it with the positive byte width determined by the storage.
  It is not extended to an inverse relation that finds all splits of a list of arbitrary length.
- The `inverse` target of `$fbits_` is `$inv_fbits_`. The previous `$inv_ibits_` notation
  was corrected by a local hint fix. The computation of the function is not changed.
- Hints are attached to type-checking relations only when they appear in premises of execution rules and functions.
  `Expand`, `Ref_ok` are `maude_compute`; `Val_ok`, `Num_ok`, `Vec_ok`,
  `Reftype_sub`, `Heaptype_sub`, `Deftype_sub` are `maude_check`.
  Validation relations without a hint (`Module_ok`, `Externaddr_ok`, etc.) are not translated, and
  definitions that use them as premises are not supported.
- `Ref_ok/sub`: `maude_subsume`, `maude_assume "Reftype_ok"`.
  The other rules each compute the actual type for one ref constructor (partial).
  The check `Ref-ok-sub(s, ref, rt)` tests whether that type is a subtype of `rt`.
  Since `Reftype_sub` is reflexive and transitive, this is the same as a derivation that nests `Ref_ok/sub` several times.
  `Reftype_ok {} |- rt` is the assumption that `rt` is a `$inst_reftype` result of a validated module or
  the type of a store instance, and is therefore closed and well-formed (not proved).
  If an unclosed `_IDX` type comes in, it may accept more than the source.
- `Heaptype_sub/trans`: `maude_trans "ANY" "EQ" "I31" "STRUCT" "ARRAY" "FUNC" "EXN" "EXTERN"`,
  `maude_assume "Heaptype_ok"`. All candidates are OK by `Heaptype_ok/abs`, so
  omitting `Heaptype_ok` is not an approximation. If bottom types (`NONE`, `NOFUNC`, `NOEXN`,
  `NOEXTERN`, `BOT`) are added to the candidates, a false query such as `NOFUNC <: ANY`
  cycles between `NONE`/`NOFUNC`. Chains through bottom are handled directly by the none/bot rules.
  Deftype intermediate values are handled by the recursion of `Deftype_sub/super`. This completeness rests on an inductive argument
  for C = {} and closed types (semantic review, not proved).
  For all 169 pairs of abstract heap types, the results were compared with values computed from the source definition, confirming agreement and termination.
- Queries during execution have C = {}, so the `_IDX`, `REC` rules are translated but do not apply.
- `BYTES` fields of `meminst`, `datainst`: `maude_array`. The source keeps memory (1 page = 65,536 cells) and
  data segment bytes as the list `byte*`. With a list, the range check `|$mem(z,x).BYTES|` counts
  the cells every time, and memory creation builds an element per cell (confirmed in the Maude profile).
  The source uses are length, element and range reads, range write (`$with_mem`), whole write (`$with_data`),
  `0^n` construction (`allocmem`), list construction (`allocdata`), and `b* 0^n` after a field pattern (`growmem`),
  all of which are forms in the table above. A byte 0 corresponds to the default value in the form `%_byte(0)`.
- `FUNCS`, `MEMS` fields of `store` and the `REFS` field of `tableinst`: `maude_map`. Wasm 1.0/2.0 also read
  the whole fields through `$funcinst(z)`, `$meminst(z)` (marked `maude_map` as functions), append with
  `s[.FUNCS =++ fi]`, and 1.0 writes a table range in `$initelem`.
  The source `$s(z).FUNCS[a]`, `$mem(z,x)`, `|$table(z,x).REFS|` count up to a cells or the size in a list,
  and the store accumulates the functions and memories of all modules of the script (Maude profile: about 40% of rewrites
  in return_call*, call_indirect; 37% in memory_copy (33 modules)).
  The source uses are element and length reads, element writes (`$with_table`, `$with_meminst`), writes inside an element
  (`$with_mem`), whole write (the tableinst value of `$with_tableinst`), list construction (`alloctable`), `r'* r^n` after a field pattern (`growtable`),
  and store `++` (`alloc*`), all of which are forms in the table above. The element types (`funcinst`, `ref`) have no default value, so
  MAP is used instead of ARRAY.

### Numeric builtins and profile

Wasm f32/f64, bits, bytes, and rounding are the responsibility of the source `hint(builtin)` implementations.
Translation support for IL Real operations and support for Wasm floating-point builtins are distinguished.
IL Real operations that are not in the current Wasm input are not supported. This does not mean that Wasm f32/f64
builtin support is removed.
Numeric builtins are compared with the Wasm numeric definitions of the corresponding revision.

The current profile is Wasm DET with `ND=false` and relaxed choice 0. Arithmetic NaN generation is distinguished from
negate, abs, copysign, and reinterpret, which preserve sign/payload.
The resource-failure choice of memory/table grow remains. DET results are not generalized to results for all
NaN and relaxed choices of the full profile.
Wasm 1.0 and 2.0 have no profiles. Their NaN propagation (numerics, `nans_N`) leaves the sign of a NaN result
open and gives a canonical payload when every NaN input is canonical, any arithmetic payload otherwise. The
float builtins are shared; only `float-default-nan` differs per version: 3.0 returns the positive canonical NaN
(deterministic profile), 1.0 and 2.0 return both canonical NaNs, so each sign is a separate rewrite. This is the
source's result set exactly, except after a non-canonical NaN input: the source then allows every arithmetic
NaN (2^23 for f32, 2^52 for f64, with both signs), and the backend gives the two canonical ones, which are among
them. Every result is a source result; the other arithmetic payloads are not produced. This is an assumption of
the backend, not of the translation. The official tests check such results as `nan:arithmetic`, which the
canonical NaNs satisfy; the reference interpreter also returns a single NaN (`Fxx.determine_binary_nan`).

`otherwise` must preserve the condition that no earlier applicable rule of the source exists.
`ElsePr` of an execution `RelD` first aligns the variables of the preceding input pattern with the current input, and
directly outputs the complement of the already known pure conditions. Relation parameters are
fixed, and the multiple matching possibilities of iterated sequence variables are not chosen arbitrarily.
A relation call that `Prem.translate_rulepr` translated to a Bool condition is negated directly as `P =/= true`,
and an equation condition with an already known result as `left =/= right`.
If a preceding type guard or new variable binding that the current caller cannot guarantee, or another matching
possibility of the input pattern, remains, the existing enabled helper is used. A rewrite condition cannot be translated
to an equational enabled helper, and the existing diagnostic is kept.

Input overlap is decided by recursively comparing source `CaseE`·`TupE`·`ListE`·`CatE`·`IterE` and the
constructors of the declared types. A sequence that necessarily contains a constructor not in the element type
does not overlap that input. Type parameters and recursive aliases whose closed constructor set cannot be
confirmed are conservatively left in the check.
No branching is done on rule or instruction names.

If a preceding `MatchCond` and a pure binding of the current fallback decompose the same computed result with the same
structure, the output variables are also aligned and reused. If the decomposition is not unique because an associative spine has several sequence
variables, this reuse is not done. A value obtained after an execution
premise is not brought into an earlier otherwise check. When the helper failure condition of an earlier
otherwise can also be checked directly with the current binding, it is replaced by the identical direct failure condition
already obtained in that caller's scope.

The 35 execution `ElsePr`s of the current Wasm source are translated as 31 checked directly on input values,
2 that reuse the fallback binding (`array.copy-gt`, `array.init_data-num`),
and 2 that use a helper (`throw_ref-handler-next`, `array.init_data-zero`).
The helper functions referenced by the last two source rules are 5 in total: 4 catch branches and
1 array range check. This is the result of the method that keeps one source rule as one execution rule,
and it is not a claim that the helpers are unavoidable even when splitting all rules is considered.
The `true` equation of a helper uses the input pattern of the preceding rule directly on the left-hand side and
checks the remaining conditions of that rule. A `false [owise]` equation that takes a general input handles
the cases where the input pattern or conditions do not match.

Value equality is inverted between `==` and `=/=`. Inversion of numeric comparisons and Bool De Morgan are applied only to
total comparisons. Comparisons and logic expressions in which a partial computation may remain are expressed as a whole
`P =/= true`, which preserves the application failure of the helper that returned `false [owise]` even for unevaluated conditions.
The automatic type check of a helper is removed only when the same check is guaranteed on the aligned inputs of all callers,
and it is checked first in the caller's execution rule.
The internal state of a context is distinguished from the source state. Agreement of search results is not a
preservation proof for arbitrary LTL properties; the current limits are recorded in [limits of verification and model checking](#limits-of-verification-and-model-checking).

### k_heatcool scope

The hint is used without arguments (former names: `rl_embedding`, `k_embedding`, `maude_context`).
The translator divides hinted rules into two kinds by AST structure. It does not divide them by the Wasm names of relations or constructors.

- **context rule**: a rule whose only premise is one execution premise of the same relation (`R: C[x] ~> C'[x']  -- R: x ~> x'`).
  In Wasm 3.0 these are `Step/ctxt-label`, `Step/ctxt-handler`, `Step/ctxt-frame`.
  It is K embedding (K book §5.4.6). Heating and cooling are both equations, and the context stays open in `K` of
  `kstate(R, K)` while the inside takes several steps.
- **split rule**: the other hinted rules. In Wasm 3.0 these are `Step/pure`, `Step/read`, `Step/ctxt-instrs`,
  `Steps/trans`, `Eval_expr`. The execution premise is divided into a request and a hole (split), and the result is returned
  to the conclusion (plug, equation).

Whether split is emitted as an equation or a rule is decided by the arrow of the relation.

- `~>` relation (`Step`): split and focus identification (`identifyFocus`) are equations. They only divide the configuration
  and do not execute, so they do not create states. One step is one rule of the inner relation.
- `~>*` relation (`Steps`, `Eval_expr`): split is a rule, because `Steps/refl` and `Steps/trans` both apply to the same request,
  which is an actual choice. These relations are used only inside the rewrite conditions of initialization.

The actual source and generated output are in [translation examples for the 8 rules](#k_heatcool-translation-examples-for-the-8-rules) below.

A split rule applies to a RuleD of an execution relation and needs at least one direct execution RulePr.
For each execution premise, only the variables among the earlier bindings that the result pattern, the remaining conditions, and the conclusion need are stored in the hole.
General conditions and output pattern checks keep their order before and after that execution.
For a single premise connected through a sequence-result relation, an identification helper is generated from the target input pattern.
From the current source rule names, `identifyPure` and `identifyRead` are generated.
ElsePr and IterPr of a hinted rule and rewrite-backed expressions are currently Unsupported.
Request sorts and return sorts are distinguished, and hole arguments get `[frozen (2)]` to prevent rule rewriting.

**Conditions and justification of equation split.** An equation, once chosen, does not backtrack, so the following must hold.

- The identification helper checks the input pattern of the target rule together with the equational premises that use only input variables (e.g.
  `c =/= 0` of if-true). An input on which no rule can execute (a single `TRAP` left at the end, etc.)
  is not split and remains `Step(c)`. Rules with patterns whose length is not determined (trap-instrs etc., below)
  are not put into the identification helper. pure, read, and Step rules must not match
  the same focus together. In Wasm 3.0, it was confirmed from the generated patterns that the trigger instructions of the three kinds of rules do not overlap (not a proof).
- The identification helper also checks the range-deciding premises, as `identifyFocus` does (the block
  type that decides m of `val^m`, etc.). Without them, both the read split that cuts `c1 c2 BLOCK` (a block that takes no values) as a whole
  and the focus split that cuts only `BLOCK` match, and the same term becomes equal to both a state that can progress and a stuck state.

  ```maude
  ceq identifyRead(Z ; (VAL* BLOCK(BT, INSTR*))) = true
    if M-3 := size(VAL*) /\ T_1* ->- nil  T_2* := blocktype-(Z, BT)
    /\ M-3 = size(T_1*) .
  ```
- An equation states equality, so there must be one way to cut each input (confluence). If the operands or the tail of a focus pattern
  contain a sequence whose length is not determined (`val*`, or `val^n` where n does not occur elsewhere in the rule),
  it overlaps the front and back of the sequence context, so there are several ways to cut, and each is a different source next state.
  Example: with trap-instrs (`val* TRAP instr* ~> TRAP`), `c1 c2 TRAP NOP` has 5 next states
  (`TRAP`, `TRAP NOP`, `c1 TRAP NOP`, `c1 TRAP`, `c1 c2 TRAP`). For such a pattern, no focus or identification equation is
  generated; the rule through the bridge and the rule inside the sequence context are each emitted as one rule
  (`heatcool.ml:absorbed_rules`). A rule uses all matches, so the next states are the same as in the source.

  ```maude
  crl [Step-pure-trap-instrs] : Step(Z ; (VAL* (TRAP INSTR*))) => Z ; TRAP
    if _or_(VAL* =/= nil, INSTR* =/= nil) .
  crl [Step-ctxt-instrs-trap-instrs] : Step(Z ; (PREFIX ((VAL* (TRAP INSTR*)) POSTFIX)))
      => Z ; (PREFIX (TRAP POSTFIX))
    if _or_(PREFIX =/= nil, POSTFIX =/= nil) /\ _or_(VAL* =/= nil, INSTR* =/= nil) .
  ```

  The decision is made only from the rule shape; in Wasm 3.0 the rules concerned are trap-instrs and throw_ref-instrs.
  `val^n` is regarded as having a determined length if n also occurs elsewhere in the rule (the block type of block, the number of
  fields of struct.new, etc.; the translator does not check whether n is actually determined by that value).
  Evidence: experiment record outside the repository (2026-10-29 trap-rule, not included in the artifact).
- A configuration of a model-checking state may contain a split request. A proposition that inspects the configuration
  must read it as `cool-all(unheat(R), K)` (the current proposition `returned` only inspects `finished(...)`).
- Execution rules apply directly to the state, so an execution rule whose result is a computed expression binds the result to a result-sort variable with `:=`
  (`reld.ml:execution_statement`). If a partial function is undefined, as for an out-of-range store, that rule
  does not apply. In the source too, a rule whose result is undefined is not a step.

The applicability conditions of a context rule are as follows. If they do not hold, it is Unsupported with a diagnostic.

- The context does not change during the inner steps: putting the premise input back into the conclusion output gives the conclusion input
  (`C'[x]` is `C[x]`). Exchanging part of the state with the inside, as frame does, is allowed.
- The sequence of the conclusion input is one context element `E`, and the premise executes the sequence variable `x` that is an argument of `E`.
- The same relation has exactly one sequence context (`val* instr* instr_1*`) of a split rule, and
  that rule has the condition `val* =/= eps \/ instr_1* =/= eps`.
- There is at least one rule that consumes `E` (closed body below).

Generated output (where the rule name of `R` is `R-r`):

```maude
kstate(z ; PREFIX E POSTFIX, K) = kstate(z ; E, hole(PREFIX, POSTFIX) K)
  if _or-else_(PREFIX =/= nil, POSTFIX =/= nil) /\ closed-R-r(x) = false .  --- instrs heating
kstate(C[x], K) = kstate(x, hole-R-r(..) K)  if closed-R-r(x) = false .   --- heating
kstate(x', hole-R-r(..) K) = kstate(C'[x'], K)  if closed-R-r(x') = true .  --- cooling
kstate(z ; s, hole(PREFIX, POSTFIX) K) = kstate(z ; PREFIX s POSTFIX, K) [owise] .  --- instrs cooling
kstate(c, K) = kstate(Step(c), K)  if plug-first(K) = false [owise] .       --- wrap as a request
cool-all(c, K)                                                               --- the configuration with all holes plugged back
unheat(r)                                                                    --- the configuration that a split request denotes
```

A closed body is the pattern at the position of `x` in those focus patterns of the sequence context whose trigger is the constructor of `E`.
That is, it is the body shape of the rules that consume `E` itself (label-vals, br-label, return-frame, etc.), and it is extracted
from the source rules, not from Wasm names. Instrs cooling applies only when the heating condition
does not hold, so it is `[owise]`. When no context equation applies any more and there is no sequence
hole waiting either, the configuration is wrapped as a request of the relation. Then the split equations find the focus, and
one rule of the relation executes one step there.

**Applicability condition.** A Step of the same relation must not apply by itself to a closed body.
Otherwise K embedding does not open that body, so it loses the inner step branches. The translator does not
check this; it was confirmed to hold for the Step rules of Wasm 3.0 (`translator/generated/output.maude`):
br/return/return_call_ref have no rules outside a context, and trap-instrs and throw_ref-instrs apply only when there are
other instructions before or after.

**State correspondence.** `cool-all(unheat(R), K)` is the source configuration. One application of a rule inside the execution state
is one source Step, and heating, cooling, split, and focus are equations, so they do not create states
(K book Theorem 13, step-for-step correspondence). It was confirmed that for fib(10) the number of compute rule applications (2,036) is the same as
with the earlier rewrite-condition driver, and that for growbuf(n=128) the number of reachable states (3,008), the final states, and the LTL counterexample are the same
(experiment record outside the repository, 2026-10-29 step2-heateq). These are checks on finite inputs, not a proof.

`Steps` and `Eval_expr` call `Step` directly without a driver. `Step` has no rule that goes into a context
rule, so this path is valid only for expressions without LABEL_/HANDLER_/FRAME_. The
constant expressions they evaluate contain no such instructions.

## k_heatcool: translation examples for the 8 rules

Below are the current source and the generated Maude statements. Auxiliary declarations and the full identification rules are omitted.

### Translation contract and structure

The actual execution `RulePr` of a `RuleD` is identified, and the existing `Prem` translation result is used. When an execution condition is met, a request and a hole are generated and the remaining conditions are translated recursively. The hole stores only those already bound variables that the inner result pattern, the remaining conditions, and the final conclusion need. When all conditions are processed, the result is plugged into the original conclusion. General conditions are not moved across the next execution premise.

No branching is done on names such as LABEL or FRAME; identification helper and hole names are generated from the source rule. No separate evaluator or general premise framework is added.

Execution requests and return results are distinguished by sort. Plug applies only to return result patterns. In `Eval_expr`, `VAL* : ValList` plays this role, so no separate typecheck is inserted. The hole argument of `_~>_` prevents rule rewriting with `[frozen (2)]`. This does not mean that equational normalization is also prohibited.

A request with no rule to execute stops in that shape. The driver regards `kstate(Step(z ; vals), none)` as completion. Search/LTL on raw requests is not identified with search/LTL on source states. Preservation of the whole meaning is not claimed from result checks on finite inputs and bounded search depth alone.

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

eq identifyPure(NOP) = true .
```

`identifyPure(INSTR*)` checks the input candidate. The original state Z is attached to the inner instruction result.

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

`identifyRead(Z ; INSTR*)` checks the input candidate. A read execution returns an instruction list, so the original state Z is attached.

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

The `identifyFocus` statements are also equations (`eq`/`ceq identifyFocus(...) = { ... }`). The nonempty condition of the source remains as a guard.
The cut position changes at every step (the result of an earlier instruction is an operand of the next instruction), so it is not kept open.
No focus pattern is generated for context rules (ctxt-label/handler/frame).

### 4. Step/ctxt-label (context rule)

```spectec
rule Step/ctxt-label:
  z; (LABEL_ n `{instr_0*} instr*)  ~>  z'; (LABEL_ n `{instr_0*} instr'*)
  -- Step: z; instr* ~> z'; instr'*
  hint(k_heatcool)
```

```maude
ceq kstate(Z ; (PREFIX ((LABEL- N-3 { INSTR_0* } INSTR*) POSTFIX)), K-4) = kstate(Z ; (LABEL- N-3 { INSTR_0* } INSTR*), hole(PREFIX, POSTFIX) K-4)
    if _or-else_(PREFIX =/= nil, POSTFIX =/= nil)
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

The closed bodies are the bodies of label-vals, br-label-zero, br-label-succ, return-label, trap-label,
return_call_ref-label, and throw_ref-label.

### 5. Step/ctxt-handler (context rule)

```spectec
rule Step/ctxt-handler:
  z; (HANDLER_ n `{catch*} instr*) ~> z'; (HANDLER_ n `{catch*} instr'*)
  -- Step: z; instr* ~> z'; instr'*
  hint(k_heatcool)
```

It has the same shape as ctxt-label (hole `hole-Step-ctxt-handler(CATCH*, N-3)`). The closed bodies are the bodies of br-handler,
return-handler, handler-vals, trap-handler, return_call_ref-handler, and throw_ref-handler-*.

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

Heating switches to the inner frame F' and keeps the outer frame F in the hole. In cooling, the store S' and the inner
frame F'' take the execution result. Instrs heating and the closed bodies (frame-vals, return-frame, trap-frame,
return_call_ref-frame-null/addr, throw_ref-frame) are generated in the same way as for ctxt-label.

### Common declarations, wrapping as a request, instrs cooling

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

The first argument of `kstate` is not frozen. The execution drivers (`wasm2maude/*-runtime.maude`, harness) start the state as
`exec(kstate(C, none))`, and `Step` rules apply directly inside it (no rewrite conditions).
Completion is `kstate(Step(z ; vals), none)`. The wast runner works the same way. The `kstate` argument of the running
command is not frozen, so `Step` rules apply directly inside it and `rew` follows one
execution. `rew` is rule-fair, so on a request to which several rules apply it may pick any rule. The reference
interpreter grows whenever it can grow, so memory.grow and table.grow requests are wrapped in `choice(R)` to take the first successor in Maude's search
order (the success rule declared first). The exhaustion check compares the sum of the number of frame holes in K and the number of
active frames in the request R with the bound.

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

The result of the first Step is passed to the next Steps. Steps/refl is kept as a rule that preserves zero executions. The second hole returns the original conclusion.

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

The sort of VAL* is ValList. Non-value lists such as NOP/TRAP and requests in execution do not match this plug pattern. The tuple shape is also the same as the original output.

### Supported scope and verification

Direct execution RulePrs, general conditions and bindings before and after execution, and chaining of multiple execution premises are supported. ElsePr and IterPr inside a hinted rule and rewrite-backed expressions are currently explicitly Unsupported. An unsupported structure is not silently reverted to a plain rule. The supported scope of the existing list contexts is kept.

Wasm 1.0 and 2.0 hint 7 of these rules (they have no `Step/ctxt-handler`).

`$evalexprs`, `$evalglobals` in `4.4-execution.modules.spectec` are function definition clauses, so they are not included in the 8 relation rules above. They keep the existing translation and call the changed Eval_expr.

Translation and Maude load check:

```sh
dune build
dune exec bin/spec2maude.exe --
test/spectec_to_maude.sh
```

The commands above check source translation, comparison of generated files, and Maude load. They do not replace execution result checks, the full official suite, performance comparison, or a preservation proof of general search/LTL meaning. Execution and suite checks are described in [ARTIFACT.md](ARTIFACT.md).

## Forms needed by Wasm 1.0 and 2.0

These cases follow the IL meaning directly; none names a Wasm construct.

- Option alias `syntax mut = MUT?`: `typecheck(v, mut) = typecheck(v, iterOpt(MUT))` (`typd.ml:translate_alias`).
- An `IterPr` that determines an unbound generator source (`STORE .. -- (if numtype = Inn /\ ..)?` determines `Inn?`)
  uses the output helper in type and definition premises too; the body binds the output by equality, so it is a
  function. An `IterPr` over an execution premise (`(Eval_expr: z; expr ~>* z; val)*` in `$instantiate`) is a request
  rewritten by rules, one rule per element, so every result of each element is kept
  (`iter_helpers.ml:rewrite_premise_statements`, request sort `S-Iteration` above the result sort S).
- Arithmetic patterns: `e + k` and `e * k` with known k bind e to `sd(v, k)` (int: `v - k`) and `v quo k`, recursively,
  and recheck `e + k = v`; a relation input keeps its constructors and solves only such a field (`BR $(l+1)`,
  `$(n * 64 * $Ki) = |..|`).
- A premise `e_1 \/ .. \/ e_n` of an execution rule that binds a variable is split into rules `id-1` .. `id-n`, one per
  disjunct (`def.ml:disjunction_script`): a rewrite rule per disjunct has exactly the source rule's steps. Equations
  and hinted rules are not split.
- Typed lists share the prelude list operations, so index, slice, and update on them use the common equations.
- An `ElsePr` selection drops the case quantifiers that occur only in the dropped result checks.
- Nested proper sorts: Wasm 1.0/2.0 mark `instr` (`maude_proper "val InstrProper"`) and `admininstr`
  (`maude_proper "val AdmininstrProper"`), where `admininstr` includes `instr`. A constructor of both owners gets
  the partition of the most specific owner (`InstrProper`), `InstrProper < AdmininstrProper` is declared
  (`Hintd.proper_edges`), and a focus trigger may be any proper subsort of the focused sort.
- A definition whose result may be undefined needs `maude_kind` as in 3.0: in Wasm 1.0, `$initelem` and
  `$initdata` (an out-of-range segment update) are marked, so `$instantiate` has no result there. In Wasm 2.0,
  `$vextunop__` and `$vextbinop__` are marked, since their clauses do not cover every shape the syntax admits, and
  `$default_`, which has no clause for `BOT`.
- `maude_subsort "instr"` on `val` is exact in 1.0 (values are `CONST`) and 3.0 (`instr` includes the
  administrative instructions), but in 2.0 `val` contains `REF.FUNC_ADDR` and `REF.HOST_ADDR`, which are
  `admininstr` but not `instr`. So `val < instr` makes a Maude variable of sort `instr` also match these two
  values. Explicit `typecheck(_, instr)` still rejects them. This is an assumption, not a proof: the two values arise only
  during execution, in `admininstr*` positions, while the positions typed `instr*` (block bodies, `LABEL_`
  continuations, the instructions after a `BR` or `RETURN`) hold instructions of the module.
- Two pattern bindings do not recheck the type of the bound variable: `(e!C).0` as a pattern binds `e` to
  `Ĉ(u)` without the case premise of `e`'s type (IL `MATCH-guess` needs `Ok_subst`), and an otherwise rule after a
  rule with a case premise inside a premise requires those case premises on its own inputs, which can only stop it
  when the predecessor's other premises already fail. In the Wasm 1.0–3.0 output the first binds only a `labelidx`
  whose range the input bounds, and the second adds only the shape check of 2.0 `vtestop-false`, which holds for
  every well-formed input.

## Upstream reports

Translating Wasm 1.0–3.0 and running each official suite on the result found these source problems, reported to
WebAssembly/spec (status as of 2026-11-04):

| Report | Problem | Upstream status | Here |
| --- | --- | --- | --- |
| [issue #2319](https://github.com/WebAssembly/spec/issues/2319) | `$binop_` passes a 64-bit shift amount to the `u32` parameter of `$ishl_`/`$ishr_`; under the IL, `i64.shl` with a count of 2^32 or more has no result (all versions). | Confirmed by the maintainers: the parameters should be `iN(N)`. Already fixed in Wasm-DSL/spectec ([c1ff19a](https://github.com/Wasm-DSL/spectec/commit/c1ff19a68ec6e5668004e0eca69ac19f8391fcda)), not yet in WebAssembly/spec. | not changed; `i64.wast` fails in every version |
| [issue #2321](https://github.com/WebAssembly/spec/issues/2321) | wasm-2.0 `$vextunop__`/`$vextbinop__` are defined only for `Inn`, so I8/I16-lane `extadd_pairwise`, `extmul`, and `dot` have no result. | Confirmed; already fixed in Wasm-DSL/spectec ([5f77115](https://github.com/Wasm-DSL/spectec/commit/5f77115bfbc3306831ca71b6d0304b0c791f95fb)), not yet in WebAssembly/spec. | fixed locally (`Jnn`, as in wasm-3.0) |
| [PR #2322](https://github.com/WebAssembly/spec/pull/2322) | wasm-2.0 lacks the context-rule fix #2218 made for wasm-1.0 (`Step/ctxt-instrs`, the frame update in `Step/ctxt-frame`, `admininstr*` in `Step/pure`, `Step/read`, `Step/ctxt-label`). | Merged ([c4a1a33](https://github.com/WebAssembly/spec/commit/c4a1a336ce725158dd52bb25e8e77b161232b37c)); the maintainers believe it was also fixed downstream. | applied locally (same change) |
| [PR #2320](https://github.com/WebAssembly/spec/pull/2320) | The SpecTec interpreter's AL encoding of `return_call_ref`. | merged (6d03200) | interpreter only; no change here |

#2319 and #2321 were found independently of the downstream fixes: they are in the pinned WebAssembly/spec
revision (spectec/REVISION) and still on its main branch. The SpecTec interpreter passes the tests of #2321 and does
not use the context rules of #2322: its AL translation does not check that `Inn_1` is `I32` or `I64`, and treats
the `ctxt` rules as administrative.
