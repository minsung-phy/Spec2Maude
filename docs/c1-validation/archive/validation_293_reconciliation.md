# Validation 293 Reconciliation

## Counts
- Old raw `eq/ceq ... = valid` rows from `git show HEAD^:output_bs.maude`: 299
- Footer / hand-written executable leftovers: 6
- Mechanical old non-footer rows: 293
- Corrected strict source primary count from `wasm-3.0/*.spectec` with `(; ;)` blocks ignored and Step relations excluded: 281
- Current primary `rl/crl => valid` rules with exact RHS `valid`: 281
- Current `eq/ceq ... = valid` leftovers: 6

## Current `eq/ceq = valid` Leftovers
- `Expand`: 1
- `Num-ok`: 1
- `Val-ok`: 4

## Reconciliation Result
The apparent `293 -> 281` gap is a counting/mapping issue, not 12 missing strict primary rules.
The old mechanical non-footer count includes 13 duplicate split/variant rows for source rules that now correctly appear once. The current strict output also includes `eval-expr-r0`, a source rule that was not represented in the old `eq/ceq = valid` set. Thus `293 - 13 + 1 = 281`.

Status counts over CSV rows:
- FOOTER_NOT_TARGET: 6
- FOUND_AS_PRIMARY_RLCRL: 280
- LABEL_RENAMED_OR_COUNT_SCRIPT_MISMATCH: 14

## Old Duplicate/Split Rows
| old_line | relation_head | old_label_guess | current_label | current_line | old first line |
|---:|---|---|---|---:|---|
| 4939 | `Limits-ok` | `limits-ok-r0` | `limits-ok-r0` | 5228 | `ceq Limits-ok ( LIMITS-OK-R00-C , CTORLBRACKDOTDOTRBRACKA2 ( LIMITS-OK-R00-N, eps ) , LIMITS-OK-R00-K ) = valid` |
| 4993 | `Limits-sub` | `limits-sub-max` | `limits-sub-max` | 5313 | `ceq Limits-sub ( LIMITS-SUB-MAX0-C , CTORLBRACKDOTDOTRBRACKA2 ( LIMITS-SUB-MAX0-N1, LIMITS-SUB-MAX0-M1 ) , CTORLBRACKDOTDOTRBRACKA2 ( LIMITS-SUB-MAX0-N2, eps ) ) = valid` |
| 5037 | `Blocktype-ok` | `blocktype-ok-valtype` | `blocktype-ok-valtype` | 5391 | `ceq Blocktype-ok ( BLOCKTYPE-OK-VALTYPE0-C , CTORWRESULTA1 ( eps ) , CTORARROWA3 ( eps, eps, eps ) ) = valid` |
| 5145 | `Instr-ok` | `instr-ok-struct-get` | `instr-ok-struct-get` | 5633 | `ceq Instr-ok ( INSTR-OK-STRUCT-GET36-C , CTORSTRUCTGETA3 ( eps, INSTR-OK-STRUCT-GET36-X, INSTR-OK-STRUCT-GET36-I ) , CTORARROWA3 ( ( CTORREFA2 ( CTORNULLA0, ( CTORWIDXA1 ( INSTR...` |
| 5161 | `Instr-ok` | `instr-ok-array-get` | `instr-ok-array-get` | 5668 | `ceq Instr-ok ( INSTR-OK-ARRAY-GET43-C , CTORARRAYGETA2 ( eps, INSTR-OK-ARRAY-GET43-X ) , CTORARROWA3 ( ( CTORREFA2 ( CTORNULLA0, ( CTORWIDXA1 ( INSTR-OK-ARRAY-GET43-X ) ) ) CTOR...` |
| 5176 | `Instr-ok` | `instr-ok-extern-convert-any` | `instr-ok-extern-convert-any` | 5703 | `ceq Instr-ok ( INSTR-OK-EXTERN-CONVERT-ANY50-C , CTOREXTERNCONVERTANYA0 , CTORARROWA3 ( ( CTORREFA2 ( eps, CTORANYA0 ) ), eps, ( CTORREFA2 ( INSTR-OK-EXTERN-CONVERT-ANY50-NULL2,...` |
| 5178 | `Instr-ok` | `instr-ok-extern-convert-any` | `instr-ok-extern-convert-any` | 5703 | `ceq Instr-ok ( INSTR-OK-EXTERN-CONVERT-ANY50-C , CTOREXTERNCONVERTANYA0 , CTORARROWA3 ( ( CTORREFA2 ( INSTR-OK-EXTERN-CONVERT-ANY50-NULL1, CTORANYA0 ) ), eps, ( CTORREFA2 ( eps,...` |
| 5180 | `Instr-ok` | `instr-ok-extern-convert-any` | `instr-ok-extern-convert-any` | 5703 | `ceq Instr-ok ( INSTR-OK-EXTERN-CONVERT-ANY50-C , CTOREXTERNCONVERTANYA0 , CTORARROWA3 ( ( CTORREFA2 ( eps, CTORANYA0 ) ), eps, ( CTORREFA2 ( eps, CTOREXTERNA0 ) ) ) ) = valid` |
| 5184 | `Instr-ok` | `instr-ok-any-convert-extern` | `instr-ok-any-convert-extern` | 5708 | `ceq Instr-ok ( INSTR-OK-ANY-CONVERT-EXTERN51-C , CTORANYCONVERTEXTERNA0 , CTORARROWA3 ( ( CTORREFA2 ( eps, CTOREXTERNA0 ) ), eps, ( CTORREFA2 ( INSTR-OK-ANY-CONVERT-EXTERN51-NUL...` |
| 5186 | `Instr-ok` | `instr-ok-any-convert-extern` | `instr-ok-any-convert-extern` | 5708 | `ceq Instr-ok ( INSTR-OK-ANY-CONVERT-EXTERN51-C , CTORANYCONVERTEXTERNA0 , CTORARROWA3 ( ( CTORREFA2 ( INSTR-OK-ANY-CONVERT-EXTERN51-NULL1, CTOREXTERNA0 ) ), eps, ( CTORREFA2 ( e...` |
| 5188 | `Instr-ok` | `instr-ok-any-convert-extern` | `instr-ok-any-convert-extern` | 5708 | `ceq Instr-ok ( INSTR-OK-ANY-CONVERT-EXTERN51-C , CTORANYCONVERTEXTERNA0 , CTORARROWA3 ( ( CTORREFA2 ( eps, CTOREXTERNA0 ) ), eps, ( CTORREFA2 ( eps, CTORANYA0 ) ) ) ) = valid` |
| 5274 | `Instr-ok` | `instr-ok-vextract-lane` | `instr-ok-vextract-lane` | 5968 | `ceq Instr-ok ( INSTR-OK-VEXTRACT-LANE103-C , CTORVEXTRACTLANEA3 ( INSTR-OK-VEXTRACT-LANE103-SH, eps, INSTR-OK-VEXTRACT-LANE103-I ) , CTORARROWA3 ( CTORV128A0, eps, ( $unpackshap...` |
| 5447 | `Module-ok` | `module-ok-r0` | `module-ok-r0` | 6330 | `ceq Module-ok ( CTORMODULEA11 ( MODULE-OK-R00-TYPES, MODULE-OK-R00-IMPORTS, MODULE-OK-R00-TAGS, MODULE-OK-R00-GLOBALS, MODULE-OK-R00-MEMS, MODULE-OK-R00-TABLES, MODULE-OK-R00-FU...` |

## Current-Only Primary Rows
| current_label | relation_head | current_line | notes |
|---|---|---:|---|
| `eval-expr-r0` | `Eval-expr` | 9242 | current strict primary rule has no corresponding old eq/ceq = valid row; source rule was not represented in old target count |

## Missing / Still Eq
No old non-footer target row is truly missing after accounting for duplicate old split rows; no old target remains as current `eq/ceq = valid`.

## Recommendation
Use 281, not 293, as the strict one-primary-rule count for the current source set unless the historical old split rows are intentionally counted as targets. The next audit should inspect why old `Eval_expr` was not part of the old `eq/ceq = valid` count and whether the generated label `instr-ok-w-if` should be normalized back to the source case name `instr-ok-if`.
