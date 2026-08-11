#!/bin/sh
set -eu

if [ "$#" -eq 1 ]; then
  output=$1
else
  exe=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
  root=$(CDPATH= cd -- "$2" && pwd)
  output=/tmp/spec2maude-premise-order.maude
  translate_log=/tmp/spec2maude-premise-order-translate.log
  cd "$root"
  rm -f "$output" "$translate_log"
  if ! perl -e '$SIG{ALRM}=sub { exit 124 }; alarm shift; exec @ARGV' \
    120 "$exe" translate -o "$output" >"$translate_log" 2>&1
  then
    cat "$translate_log" >&2
    echo 'premise-order translation failed' >&2
    exit 1
  fi
  grep -Eq '^\[spec2maude\] diagnostics: .*fatal=0 unsupported=0' "$translate_log"
fi

if grep -q '^--- PARTIAL/INCOMPLETE VERIFICATION OUTPUT:' "$output"; then
  echo 'complete premise-order output was marked partial' >&2
  exit 1
fi

condition_line () {
  awk -v head="$1" 'index($0, head) { getline; print; exit }' "$output"
}

matching_line () {
  awk -v head="$1" 'index($0, head) { print; exit }' "$output"
}

require_contains () {
  line=$1
  text=$2
  message=$3
  if ! printf '%s\n' "$line" | grep -Fq "$text"; then
    echo "$message" >&2
    exit 1
  fi
}

require_not_contains () {
  line=$1
  text=$2
  message=$3
  if printf '%s\n' "$line" | grep -Fq "$text"; then
    echo "$message" >&2
    exit 1
  fi
}

require_before () {
  line=$1
  left=$2
  right=$3
  message=$4
  if ! printf '%s\n' "$line" | awk -v left="$left" -v right="$right" '
      { l = index($0, left); r = index($0, right) }
      END { exit !(l > 0 && r > l) }
    '
  then
    echo "$message" >&2
    exit 1
  fi
}

require_statement_before () {
  first=$1
  second=$2
  message=$3
  if ! awk -v first="$first" -v second="$second" '
      index($0, first) && first_line == 0 { first_line = NR }
      index($0, second) && second_line == 0 { second_line = NR }
      END {
        exit !(first_line > 0 && second_line > first_line)
      }
    ' "$output"
  then
    echo "$message" >&2
    exit 1
  fi
}

step=$(condition_line 'crl [step-ctxt-instrs]')
require_before "$step" \
  'helper.context-split.step(STREAM1:SpectecTerminals)' \
  'rel.step(config.sym(Z:SpectecTerminal, INSTR_STAR:SpectecTerminals)) =>' \
  'ctxt-instrs split no longer precedes its self-recursive rewrite'
if printf '%s\n' "$step" \
    | grep -Eq 'helper\.subtype-project-seq\.step-pure|_or_\(_=/=_\(VAL_STAR'
then
  echo 'ctxt-instrs repeated projection/progress already certified by its strict split helper' >&2
  exit 1
fi

require_statement_before \
  'crl [step-read-ref-test-true]' \
  'crl [step-read-ref-test-false]' \
  'Step_read Ref.test clauses no longer preserve SpecTec source order'
require_statement_before \
  'crl [step-read-ref-cast-succeed]' \
  'crl [step-read-ref-cast-fail]' \
  'Step_read Ref.cast clauses no longer preserve SpecTec source order'

alloctypes=$(condition_line 'ceq def.alloctypes(TYPE_PRIME_STAR:SpectecTerminals')
require_before "$alloctypes" \
  'X:SpectecTerminal := uN.wrap(len(DEFTYPE_PRIME_STAR:SpectecTerminals))' \
  'DEFTYPE_STAR:SpectecTerminals := def.subst-all-deftypes' \
  'alloctypes no longer binds the length before subst_all_deftypes'

allocmodule=$(condition_line 'ceq def.allocmodule(S:SpectecTerminal')
forward='FA_STAR:SpectecTerminals := helper.iter-count.allocmodule(len(FUNC_STAR:SpectecTerminals), 0, S:SpectecTerminal)'
provisional='XI_STAR:SpectecTerminals := def.allocexports(rec.moduleinst(eps, AA_I_STAR:SpectecTerminals AA_STAR:SpectecTerminals, GA_I_STAR:SpectecTerminals GA_STAR:SpectecTerminals, MA_I_STAR:SpectecTerminals MA_STAR:SpectecTerminals, TA_I_STAR:SpectecTerminals TA_STAR:SpectecTerminals, FA_I_STAR:SpectecTerminals FA_STAR:SpectecTerminals, eps, eps, eps), EXPORT_STAR:SpectecTerminals)'
moduleinst='MODULEINST:SpectecTerminal := rec.moduleinst(DT_STAR:SpectecTerminals, AA_I_STAR:SpectecTerminals AA_STAR:SpectecTerminals, GA_I_STAR:SpectecTerminals GA_STAR:SpectecTerminals, MA_I_STAR:SpectecTerminals MA_STAR:SpectecTerminals, TA_I_STAR:SpectecTerminals TA_STAR:SpectecTerminals, FA_I_STAR:SpectecTerminals FA_STAR:SpectecTerminals, DA_STAR:SpectecTerminals, EA_STAR:SpectecTerminals, XI_STAR:SpectecTerminals)'
allocfuncs='tuple(S_7:SpectecTerminal seq(FA_STAR:SpectecTerminals)) := def.allocfuncs(S_6:SpectecTerminal, helper.iter-map.allocmodule.13(X_STAR:SpectecTerminals, DT_STAR:SpectecTerminals), helper.iter-zip.allocmodule.6(EXPR_F_STAR:SpectecTerminals, LOCAL_STAR_STAR:SpectecTerminals, X_STAR:SpectecTerminals), helper.iter-count.allocmodule.3(len(FUNC_STAR:SpectecTerminals), MODULEINST:SpectecTerminal))'
require_contains "$allocmodule" "$forward" \
  'allocmodule no longer computes the exact source-derived forward function addresses'
require_contains "$allocmodule" "$provisional" \
  'allocexports no longer receives the provisional moduleinst with the guessed function addresses'
require_contains "$allocmodule" "$moduleinst" \
  'the final moduleinst no longer retains the guessed function addresses and allocated exports'
require_contains "$allocmodule" "$allocfuncs" \
  'allocfuncs no longer consumes S_6 and repeated MODULEINST while matching the guessed function addresses'
require_before "$allocmodule" "$forward" "$provisional" \
  'allocmodule no longer binds its forward function addresses before exports'
require_before "$allocmodule" "$provisional" "$moduleinst" \
  'allocmodule no longer constructs exports before moduleinst'
require_before "$allocmodule" "$moduleinst" "$allocfuncs" \
  'allocmodule no longer checks allocfuncs against the bound function addresses'

memory_fill=$(condition_line 'crl [step-read-memory-fill-succ]')
require_contains "$memory_fill" \
  '_=/=_(N:Nat, 0)' \
  'memory.fill successor no longer inlines the singleton complement of its zero predecessor'
if grep -q 'helper.enabledness.step-read-memory-fill-zero' "$output"; then
  echo 'memory.fill zero complement unexpectedly materialized a one-rule helper' >&2
  exit 1
fi

step_pure=$(condition_line 'crl [step-pure]')
require_contains "$step_pure" \
  'rel.step-pure(INSTR_STAR:SpectecTerminals) => INSTR_PRIME_STAR:SpectecTerminals' \
  'Step/pure lost its source relation premise'
if printf '%s\n' "$step_pure" | grep -Fq 'typecheck(Z:SpectecTerminal, syn.state)'; then
  echo 'Step/pure repeated an input-state check already enforced by config membership' >&2
  exit 1
fi

step_read=$(condition_line 'crl [step-read]')
require_contains "$step_read" \
  'rel.step-read(config.sym(Z:SpectecTerminal, INSTR_STAR:SpectecTerminals)) => INSTR_PRIME_STAR:SpectecTerminals' \
  'Step/read lost its source relation premise'
if printf '%s\n' "$step_read" | grep -Fq 'typecheck(Z:SpectecTerminal, syn.state)'; then
  echo 'Step/read repeated an input-state check already enforced by config membership' >&2
  exit 1
fi

step_context=$(condition_line 'crl [step-ctxt-instrs]')
require_before "$step_context" \
  'rel.step(config.sym(Z:SpectecTerminal, INSTR_STAR:SpectecTerminals))' \
  'typecheck(config.sym(Z_PRIME:SpectecTerminal, INSTR_PRIME_STAR:SpectecTerminals), syn.config)' \
  'Step/ctxt-instrs no longer retains its whole recursive rewrite-result config guard'
step_context_rule=$(matching_line 'crl [step-ctxt-instrs]')
require_contains "$step_context_rule" \
  'PATTERN1:SpectecTerminals (INSTR_PRIME_STAR:SpectecTerminals INSTR_1_STAR:SpectecTerminals)' \
  'Step/ctxt-instrs no longer reuses its certified raw value-prefix pattern'
if printf '%s\n' "$step_context" \
    | grep -Eq 'helper\.subtype-project-seq\.step-pure|_or_\(_=/=_\(VAL_STAR'
then
  echo 'Step/ctxt-instrs retained projection/progress implied by its strict split helper' >&2
  exit 1
fi
if printf '%s\n' "$step_context_rule" | grep -Fq 'helper.iter-map'; then
  echo 'Step/ctxt-instrs retained a direct projection/reinjection map' >&2
  exit 1
fi
if printf '%s\n' "$step_context" \
    | grep -Eq 'syn\.state\)|typecheckSeq\('; then
  echo 'Step/ctxt-instrs retained a payload check implied by its whole config guard' >&2
  exit 1
fi

step_frame=$(condition_line 'crl [step-ctxt-frame]')
require_contains "$step_frame" \
  'typecheck(config.sym(state.sym(S_PRIME:SpectecTerminal, F_PRIME_PRIME:SpectecTerminal), INSTR_PRIME_STAR:SpectecTerminals), syn.config)' \
  'Step/ctxt-frame lost its whole recursive rewrite-result config guard'
if printf '%s\n' "$step_frame" \
    | grep -Eq 'syn\.(store|frame|state)\)|typecheckSeq\('; then
  echo 'Step/ctxt-frame retained a nested payload check implied by its whole config guard' >&2
  exit 1
fi

steps_trans=$(condition_line 'crl [steps-trans]')
require_contains "$steps_trans" \
  'typecheck(config.sym(Z_PRIME:SpectecTerminal, INSTR_PRIME_STAR:SpectecTerminals), syn.config)' \
  'Steps/trans lost its first whole rewrite-result config guard'
require_contains "$steps_trans" \
  'typecheck(config.sym(Z_PRIME_PRIME:SpectecTerminal, INSTR_PRIME_PRIME_STAR:SpectecTerminals), syn.config)' \
  'Steps/trans lost its transitive whole rewrite-result config guard'
if printf '%s\n' "$steps_trans" \
    | grep -Eq 'syn\.state\)|typecheckSeq\('; then
  echo 'Steps/trans retained payload checks implied by its whole config guards' >&2
  exit 1
fi

eval_expr=$(condition_line 'crl [eval-expr-rule-1]')
require_contains "$eval_expr" \
  'typecheck(config.sym(Z_PRIME:SpectecTerminal, PATTERN1:SpectecTerminals), syn.config)' \
  'Eval_expr lost its whole Steps output config guard'
if printf '%s\n' "$eval_expr" \
    | grep -Eq 'syn\.state\)|typecheckSeq\('; then
  echo 'Eval_expr retained payload checks implied by its whole config guard' >&2
  exit 1
fi


memory_fill_oob=$(condition_line 'crl [step-read-memory-fill-oob]')
require_contains "$memory_fill_oob" \
  '(_>_(_+_(proj.uN.wrap.0(I:SpectecTerminal), N:Nat), len(value('\''BYTES, def.mem(Z:SpectecTerminal, X:SpectecTerminal))))) = true' \
  'memory.fill lost its source OOB decision'
if printf '%s\n' "$memory_fill_oob" | grep -Fq 'typecheck(Z:SpectecTerminal, syn.state)'; then
  echo 'memory.fill repeated an input-state check already enforced by config membership' >&2
  exit 1
fi

memory_fill_bad_memidx=$(condition_line \
  'crl [helper-enabledness-step-read-memory-fill-oob-source-false-1]')
require_contains "$memory_fill_bad_memidx" \
  '(not_(indexDefined(value('\''MEMS, value('\''MODULE, def.fof(Z:SpectecTerminal))), proj.uN.wrap.0(X:SpectecTerminal)))) = true' \
  'memory.fill enabledness lost its invalid-memory-index complement'

memory_fill_in_bounds=$(condition_line \
  'crl [helper-enabledness-step-read-memory-fill-oob-source-false-3]')
require_contains "$memory_fill_in_bounds" \
  '(_<=_(_+_(proj.uN.wrap.0(I:SpectecTerminal), N:Nat), len(value('\''BYTES, def.mem(Z:SpectecTerminal, X:SpectecTerminal))))) = true' \
  'memory.fill enabledness lost its in-bounds complement'
if printf '%s\n' "$memory_fill_in_bounds" | grep -Fq 'typecheck(Z:SpectecTerminal, syn.state)'; then
  echo 'memory.fill enabledness repeated an input-state check already enforced by config membership' >&2
  exit 1
fi
if printf '%s\n' "$memory_fill_in_bounds" | grep -Fq 'typecheckSeq(((instr.const'; then
  echo 'memory.fill enabledness repeated an instruction check already enforced by config membership' >&2
  exit 1
fi
for factored in \
  'AT:SpectecTerminal := helper.subtype-project.num' \
  'VAL:SpectecTerminal := helper.subtype-project.step-pure' \
  'typecheck(I:SpectecTerminal, syn.num(helper.subtype-inject.num(AT:SpectecTerminal)))' \
  'typecheck(uN.wrap(N:Nat), syn.num(helper.subtype-inject.num(AT:SpectecTerminal)))'
do
  require_not_contains "$memory_fill_in_bounds" "$factored" \
    'memory.fill enabledness repeated a source-prefix guard already established by its caller'
done

require_statement_before \
  'crl [helper-enabledness-step-read-memory-fill-oob-source-false-3]' \
  'crl [helper-enabledness-step-read-memory-fill-oob-source-false-1]' \
  'memory.fill enabledness no longer tries its validated in-bounds branch first'

if printf '%s\n' "$memory_fill" | grep -Fq 'typecheck(Z:SpectecTerminal, syn.state)'; then
  echo 'memory.fill successor repeated a state guard already established by its enabledness helper' >&2
  exit 1
fi
if printf '%s\n' "$memory_fill" | grep -Fq 'typecheckSeq(((instr.const'; then
  echo 'memory.fill successor repeated an instruction guard already established by its enabledness helper' >&2
  exit 1
fi
for retained in \
  'VAL:SpectecTerminal := helper.subtype-project.step-pure' \
  'typecheck(I:SpectecTerminal, syn.num(helper.subtype-inject.num(AT:SpectecTerminal)))' \
  'typecheck(uN.wrap(N:Nat), syn.num(helper.subtype-inject.num(AT:SpectecTerminal)))'
do
  require_contains "$memory_fill" "$retained" \
    'memory.fill successor lost a binding or dependent guard that cannot be factored across the helper witness'
done
require_not_contains "$memory_fill" \
  'typecheck(N:Nat, syn.nat)' \
  'memory.fill successor repeated an immutable LHS guard established by its enabledness helper'

memory_fill_zero=$(condition_line 'crl [step-read-memory-fill-zero]')
require_before "$memory_fill_zero" \
  'N:Nat = 0' \
  'helper.enabledness.step-read-memory-fill-oob' \
  'memory.fill zero rule no longer checks its source decision before enabledness'
if printf '%s\n' "$memory_fill_zero" | grep -Fq 'typecheck(Z:SpectecTerminal, syn.state)'; then
  echo 'memory.fill zero rule repeated a state guard already established by its enabledness helper' >&2
  exit 1
fi
for retained in \
  'AT:SpectecTerminal :=' \
  'VAL:SpectecTerminal :=' \
  'typecheck(I:SpectecTerminal' \
  'typecheck(uN.wrap(N:Nat)'
do
  require_contains "$memory_fill_zero" "$retained" \
    'memory.fill zero rule lost a binding or dependent guard that cannot be factored across the helper witness'
done
require_not_contains "$memory_fill_zero" \
  'typecheck(N:Nat, syn.nat)' \
  'memory.fill zero rule repeated an immutable LHS guard established by its enabledness helper'

with_mem=$(condition_line 'ceq def.with-mem(Z:SpectecTerminal')
with_mem_rhs=$(matching_line 'ceq def.with-mem(Z:SpectecTerminal')
require_contains "$with_mem_rhs" \
  'spliceRun(value('\''BYTES' \
  'with_mem no longer uses the representation-preserving run splice for its source SliceP update'
require_contains "$with_mem" \
  'typecheck(X:SpectecTerminal, syn.idx)' \
  'with_mem lost the source index guard required before memory lookup'
if printf '%s\n' "$with_mem" | grep -Fq 'typecheck(state.sym'; then
  echo 'with_mem retained a whole-state typecheck proved by its total constructor payloads' >&2
  exit 1
fi

free_br_table=$(condition_line 'ceq def.free-instr(instr.br-table')
require_contains "$free_br_table" \
  'typecheck(instr.br-table' \
  'free-instr lost the constructor category check required by its source clause'
for redundant in \
  'typecheckSeq(LABELIDX_STAR:SpectecTerminals, syn.labelidx)' \
  'typecheck(LABELIDX_PRIME:SpectecTerminal, syn.labelidx)'
do
  require_not_contains "$free_br_table" "$redundant" \
    'free-instr retained a payload check implied by its whole constructor check'
done

call_ref=$(condition_line 'crl [step-read-call-ref-func]')
for redundant in \
  'typecheck(comptype.func-sym(list.wrap(T_1_STAR:SpectecTerminals), list.wrap(T_2_STAR:SpectecTerminals)), syn.comptype)' \
  'typecheck(func.func(X:SpectecTerminal, PATTERN2:SpectecTerminals, INSTR_STAR:SpectecTerminals), syn.funccode)' \
  'typecheckSeq(T_1_STAR:SpectecTerminals, syn.valtype)' \
  'typecheck(list.wrap(T_1_STAR:SpectecTerminals), syn.resulttype)' \
  'typecheckSeq(T_2_STAR:SpectecTerminals, syn.valtype)' \
  'typecheck(list.wrap(T_2_STAR:SpectecTerminals), syn.resulttype)' \
  'typecheck(X:SpectecTerminal, syn.typeidx)' \
  'typecheckSeq(PATTERN2:SpectecTerminals, syn.local)' \
  'typecheckSeq(INSTR_STAR:SpectecTerminals, syn.expr)'
do
  require_not_contains "$call_ref" "$redundant" \
    'call_ref retained constructor payload validation implied by its typed subject'
done

store_pack=$(condition_line 'crl [step-store-pack-val]')
require_contains "$store_pack" \
  'typecheck(storeop.wrap(sz.wrap(N:Nat)), syn.storeop(helper.subtype-inject.num(INN:SpectecTerminal)))' \
  'store-pack lost its source constructor typecheck'
require_not_contains "$store_pack" \
  'typecheckSeq(storeop.wrap(sz.wrap(N:Nat)), syn.storeop(helper.subtype-inject.num(INN:SpectecTerminal)))' \
  'store-pack retained a singleton sequence check implied by the preceding constructor typecheck'
require_not_contains "$store_pack" \
  'typecheck(I:SpectecTerminal, syn.num(PATTERN1:SpectecTerminal))' \
  'store-pack retained a typecheck already established through the projection round-trip'

for retained in \
  'indexDefined(def.funcinst(Z:SpectecTerminal), A:Nat)' \
  'N:Nat := len(VAL_STAR:SpectecTerminals)' \
  'FI:SpectecTerminal := index(def.funcinst(Z:SpectecTerminal), A:Nat)' \
  'RESULT1:SpectecTerminal := rel.expand(value('\''TYPE, FI:SpectecTerminal))' \
  'comptype.func-sym(list.wrap(T_1_STAR:SpectecTerminals), list.wrap(T_2_STAR:SpectecTerminals)) := RESULT1:SpectecTerminal' \
  'N:Nat = len(T_1_STAR:SpectecTerminals)' \
  'M:Nat := len(T_2_STAR:SpectecTerminals)' \
  'func.func(X:SpectecTerminal, PATTERN2:SpectecTerminals, INSTR_STAR:SpectecTerminals) := value('\''CODE, FI:SpectecTerminal)' \
  'tuple(seq(T_STAR:SpectecTerminals)) := helper.pattern-zip.step-read(PATTERN2:SpectecTerminals)' \
  'F:SpectecTerminal := rec.frame('
do
  require_contains "$call_ref" "$retained" \
    'call_ref lost a source/dependent condition while removing payload validation'
done

step_block=$(condition_line 'crl [step-read-block]')
require_contains "$step_block" \
  'M:Nat = len(T_1_STAR:SpectecTerminals)' \
  'typed-subject lowering removed a dependent block payload-length condition'
require_not_contains "$step_block" \
  'typecheck(instrtype.sym(list.wrap(T_1_STAR:SpectecTerminals), eps, list.wrap(T_2_STAR:SpectecTerminals)), syn.instrtype)' \
  'block retained whole-result validation implied by its typed producer'
cast_fail=$(condition_line 'crl [step-read-br-on-cast-fail-fail]')
require_contains "$cast_fail" \
  'helper.truth-refute-entry.step-read' \
  'br_on_cast_fail no longer uses the source-complete false worklist decision'
if printf '%s\n' "$cast_fail" | grep -Fq 'helper.enabled-false-entry'; then
  echo 'br_on_cast_fail retained an administrative enabledness wrapper for an identical predecessor head' >&2
  exit 1
fi

br_table=$(condition_line 'crl [step-pure-br-table-lt]')
require_contains "$br_table" \
  '_<_(proj.uN.wrap.0(I:SpectecTerminal), len(L_STAR:SpectecTerminals))' \
  'br_table lost its source length comparison while removing an implied domain guard'
if printf '%s\n' "$br_table" | grep -Fq 'indexDefined('; then
  echo 'br_table retained indexDefined implied by the preceding exact length bound' >&2
  exit 1
fi

forward_step=$(matching_line 'ceq helper.iter-count.allocmodule(s COUNT1:Nat')
forward_formula=$(condition_line 'ceq helper.iter-count.allocmodule(s COUNT1:Nat')
require_contains "$forward_step" \
  'helper.iter-count.allocmodule(s COUNT1:Nat, I_F:Nat, S:SpectecTerminal) = OUTPUT1:Nat helper.iter-count.allocmodule(COUNT1:Nat, s I_F:Nat, S:SpectecTerminal)' \
  'allocmodule forward-address generation no longer decrements its count and increments its source index'
require_contains "$forward_formula" \
  "OUTPUT1:Nat := _+_(len(value('FUNCS, S:SpectecTerminal)), I_F:Nat)" \
  'allocmodule forward-address generation no longer implements |s.FUNCS| + i_F'

grep -q '^  op helper.iter-count.rolldt : Nat Nat Nat SpectecTerminals -> SpectecTerminals \.[[:space:]]*$' "$output"
rolldt=$(matching_line 'ceq def.rolldt(X:SpectecTerminal')
rolldt_conditions=$(condition_line 'ceq def.rolldt(X:SpectecTerminal')
require_contains "$rolldt" \
  'helper.iter-count.rolldt(N:Nat, 0, N:Nat, SUBTYPE_STAR:SpectecTerminals)' \
  'rolldt no longer passes its count as an immutable ListN capture'
require_before "$rolldt_conditions" \
  'rectype.rec(list.wrap(SUBTYPE_STAR:SpectecTerminals)) := def.rollrt(X:SpectecTerminal, RECTYPE:SpectecTerminal)' \
  'N:Nat := len(SUBTYPE_STAR:SpectecTerminals)' \
  'rolldt no longer derives its caller count after binding the source subtype sequence'

rolldt_step=$(matching_line 'ceq helper.iter-count.rolldt(s COUNT1:Nat')
rolldt_step_conditions=$(condition_line 'ceq helper.iter-count.rolldt(s COUNT1:Nat')
require_contains "$rolldt_step" \
  'helper.iter-count.rolldt(s COUNT1:Nat, I:Nat, N:Nat, SUBTYPE_STAR:SpectecTerminals) = OUTPUT1:SpectecTerminal helper.iter-count.rolldt(COUNT1:Nat, s I:Nat, N:Nat, SUBTYPE_STAR:SpectecTerminals)' \
  'rolldt helper no longer decrements the work count, increments the index, and preserves its original captures'
require_contains "$rolldt_step_conditions" \
  'N:Nat = len(SUBTYPE_STAR:SpectecTerminals)' \
  'rolldt helper no longer checks the immutable original count against the original subtype sequence'
