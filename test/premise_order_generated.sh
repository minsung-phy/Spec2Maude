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
  '(_or_(_=/=_(VAL_STAR:SpectecTerminals, eps), _=/=_(INSTR_1_STAR:SpectecTerminals, eps))) = true' \
  'typecheckSeq(VAL_STAR:SpectecTerminals, syn.val)' \
  'ctxt-instrs source-category guard no longer follows its progress guard'
require_before "$step" \
  '(_or_(_=/=_(VAL_STAR:SpectecTerminals, eps), _=/=_(INSTR_1_STAR:SpectecTerminals, eps))) = true' \
  'rel.step(config.sym(Z:SpectecTerminal, INSTR_STAR:SpectecTerminals)) =>' \
  'ctxt-instrs progress guard no longer precedes its self-recursive rewrite'
require_before "$step" \
  'typecheckSeq(VAL_STAR:SpectecTerminals, syn.val)' \
  'rel.step(config.sym(Z:SpectecTerminal, INSTR_STAR:SpectecTerminals)) =>' \
  'ctxt-instrs self-recursive rewrite crossed its ready source-category guard'
require_not_contains "$step" \
  'typecheckSeq(VAL_STAR:SpectecTerminals, syn.instr)' \
  'ctxt-instrs retained target membership implied by val <: instr'
if printf '%s\n' "$step" | grep -Eq 'helper\.context-'
then
  echo 'ctxt-instrs retained a source-free context scanner' >&2
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
allocfuncs='tuple(S_7:SpectecTerminal seq(FA_STAR:SpectecTerminals)) := def.allocfuncs(S_6:SpectecTerminal, helper.iter-map.allocmodule.8(X_STAR:SpectecTerminals, DT_STAR:SpectecTerminals), helper.iter-zip.allocmodule.6(EXPR_F_STAR:SpectecTerminals, LOCAL_STAR_STAR:SpectecTerminals, X_STAR:SpectecTerminals), helper.iter-count.allocmodule.3(len(FUNC_STAR:SpectecTerminals), MODULEINST:SpectecTerminal))'
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
  'VAL_STAR:SpectecTerminals (INSTR_PRIME_STAR:SpectecTerminals INSTR_1_STAR:SpectecTerminals)' \
  'Step/ctxt-instrs no longer preserves its source value prefix'
if printf '%s\n' "$step_context" \
    | grep -Eq 'helper\.context-'
then
  echo 'Step/ctxt-instrs retained a source-free context scanner' >&2
  exit 1
fi
if printf '%s\n' "$step_context_rule" | grep -Fq 'helper.iter-map'; then
  echo 'Step/ctxt-instrs retained a direct projection/reinjection map' >&2
  exit 1
fi
require_contains "$step_context" \
  'typecheckSeq(VAL_STAR:SpectecTerminals, syn.val)' \
  'Step/ctxt-instrs lost its source val* membership guard'
require_not_contains "$step_context" \
  'typecheckSeq(VAL_STAR:SpectecTerminals, syn.instr)' \
  'Step/ctxt-instrs retained target membership implied by val <: instr'
require_not_contains "$step_context" \
  'helper.subtype-' \
  'Step/ctxt-instrs retained an identity subtype helper'
if printf '%s\n' "$step_context" | grep -Eq 'syn\.state\)'; then
  echo 'Step/ctxt-instrs retained an input-state check implied by config membership' >&2
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
  'typecheck(config.sym(Z_PRIME:SpectecTerminal, VAL_STAR:SpectecTerminals), syn.config)' \
  'Eval_expr lost its whole Steps output config guard'
require_contains "$eval_expr" \
  'typecheckSeq(VAL_STAR:SpectecTerminals, syn.val)' \
  'Eval_expr lost the source-category guard for its identity SubE pattern'
if printf '%s\n' "$eval_expr" \
    | grep -Eq 'syn\.state\)'; then
  echo 'Eval_expr retained a state check implied by its whole config guard' >&2
  exit 1
fi

pair_inverse=$(condition_line 'ceq def.ivadd-pairwise(')
require_contains "$pair_inverse" 'builtin.inv-concat(' \
  'fixed pair reconstruction lost its declared outer inverse'
require_contains "$pair_inverse" 'helper.unzip2.ivadd-pairwise(' \
  'fixed pair reconstruction lost its structural unzip'
require_contains "$pair_inverse" 'def.concat(' \
  'fixed pair reconstruction lost its whole forward recheck'
require_before "$pair_inverse" 'builtin.inv-concat(' \
  'helper.unzip2.ivadd-pairwise(' \
  'fixed pair reconstruction no longer calls the outer inverse first'
require_before "$pair_inverse" 'helper.unzip2.ivadd-pairwise(' 'def.concat(' \
  'fixed pair reconstruction no longer rechecks the forward call after unzip'

unzip2=$(matching_line 'ceq helper.unzip2.ivadd-pairwise(')
require_contains "$unzip2" \
  'seq(HEAD1:SpectecTerminal HEAD2:SpectecTerminal) STREAM1:SpectecTerminals' \
  'unzip2 no longer consumes exact two-element chunks'
for forbidden in 'builtin.inv-concat' 'slice(' 'drop('
do
  require_not_contains "$unzip2" "$forbidden" \
    'unzip2 regained inverse or partition ownership'
done

concatn_inverse=$(condition_line 'crl [step-read-array-new-data-num]')
require_contains "$concatn_inverse" 'builtin.inv-concatn(' \
  'fixed concatn reconstruction lost its declared outer inverse'
require_contains "$concatn_inverse" 'helper.decode-chunks.step-read(' \
  'fixed concatn reconstruction lost its structural decoder'
require_contains "$concatn_inverse" 'def.concatn(' \
  'fixed concatn reconstruction lost its whole forward recheck'
require_before "$concatn_inverse" 'builtin.inv-concatn(' \
  'len(CHUNK1:SpectecTerminals) = N:Nat' \
  'fixed concatn reconstruction no longer checks the inverse chunk count'
require_before "$concatn_inverse" 'len(CHUNK1:SpectecTerminals) = N:Nat' \
  'helper.decode-chunks.step-read(' \
  'fixed concatn reconstruction decodes before validating the chunk count'
require_before "$concatn_inverse" 'helper.decode-chunks.step-read(' 'def.concatn(' \
  'fixed concatn reconstruction no longer rechecks the whole forward call'

decode_chunks=$(condition_line 'ceq helper.decode-chunks.step-read(')
require_contains "$decode_chunks" 'builtin.inv-zbytes(' \
  'chunk decoder lost its declared element inverse'
require_contains "$decode_chunks" 'builtin.zbytes(' \
  'chunk decoder lost its element forward recheck'
for forbidden in 'builtin.inv-concatn' 'slice(' 'drop('
do
  require_not_contains "$decode_chunks" "$forbidden" \
    'chunk decoder regained outer inverse or partition ownership'
done
if grep -Eq 'helper\.(inverse-pair|inverse-chunks)' "$output"; then
  echo 'obsolete partition-owning inverse helper survived' >&2
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
if printf '%s\n' "$memory_fill_in_bounds" | grep -Fq 'typecheckSeq(((const'; then
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
if printf '%s\n' "$memory_fill" | grep -Fq 'typecheckSeq(((const'; then
  echo 'memory.fill successor repeated an instruction guard already established by its enabledness helper' >&2
  exit 1
fi
for retained in \
  'typecheck(AT:SpectecTerminal, syn.addrtype)' \
  'typecheck(AT:SpectecTerminal, syn.numtype)' \
  'typecheck(I:SpectecTerminal, syn.num(AT:SpectecTerminal))' \
  'typecheck(VAL:SpectecTerminal, syn.val)' \
  'typecheck(uN.wrap(N:Nat), syn.num(AT:SpectecTerminal))'
do
  require_contains "$memory_fill" "$retained" \
    'memory.fill successor lost a source guard required by direct subtype identity'
done
require_not_contains "$memory_fill" \
  'typecheck(VAL:SpectecTerminal, syn.instr)' \
  'memory.fill successor retained target membership implied by val <: instr'
require_not_contains "$memory_fill" \
  'helper.subtype-' \
  'memory.fill successor retained an identity subtype helper'
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
  'typecheck(AT:SpectecTerminal, syn.addrtype)' \
  'typecheck(AT:SpectecTerminal, syn.numtype)' \
  'typecheck(I:SpectecTerminal, syn.num(AT:SpectecTerminal))' \
  'typecheck(VAL:SpectecTerminal, syn.val)' \
  'typecheck(uN.wrap(N:Nat), syn.num(AT:SpectecTerminal))'
do
  require_contains "$memory_fill_zero" "$retained" \
    'memory.fill zero rule lost a source guard required by direct subtype identity'
done
require_not_contains "$memory_fill_zero" \
  'typecheck(VAL:SpectecTerminal, syn.instr)' \
  'memory.fill zero rule retained target membership implied by val <: instr'
require_not_contains "$memory_fill_zero" \
  'helper.subtype-' \
  'memory.fill zero rule retained an identity subtype helper'
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
  'typecheck(storeop.wrap(sz.wrap(N:Nat)), syn.storeop(INN:SpectecTerminal))' \
  'store-pack lost its source constructor typecheck'
require_contains "$store_pack" \
  '(isOpt(storeop.wrap(sz.wrap(N:Nat)))) = true' \
  'store-pack lost its optional-shape check'
require_not_contains "$store_pack" \
  'typecheckSeq(storeop.wrap(sz.wrap(N:Nat)), syn.storeop(INN:SpectecTerminal))' \
  'store-pack retained a singleton sequence check implied by the constructor typecheck'
require_not_contains "$store_pack" \
  'typecheck(I:SpectecTerminal, syn.num(PATTERN1:SpectecTerminal))' \
  'store-pack retained a typecheck already established through the projection round-trip'

for retained in \
  'indexDefined(def.funcinst(Z:SpectecTerminal), A:Nat)' \
  'N:Nat := len(VAL_STAR:SpectecTerminals)' \
  'typecheckSeq(VAL_STAR:SpectecTerminals, syn.val)' \
  'FI:SpectecTerminal := index(def.funcinst(Z:SpectecTerminal), A:Nat)' \
  'RESULT1:SpectecTerminal := rel.expand(value('\''TYPE, FI:SpectecTerminal))' \
  'comptype.func-sym(list.wrap(T_1_STAR:SpectecTerminals), list.wrap(T_2_STAR:SpectecTerminals)) := RESULT1:SpectecTerminal' \
  'N:Nat = len(T_1_STAR:SpectecTerminals)' \
  'M:Nat := len(T_2_STAR:SpectecTerminals)' \
  'func.func(X:SpectecTerminal, PATTERN1:SpectecTerminals, INSTR_STAR:SpectecTerminals) := value('\''CODE, FI:SpectecTerminal)' \
  'tuple(seq(T_STAR:SpectecTerminals)) := helper.pattern-zip.step-read(PATTERN1:SpectecTerminals)' \
  'F:SpectecTerminal := rec.frame('
do
  require_contains "$call_ref" "$retained" \
    'call_ref lost a source/dependent condition while removing payload validation'
done
require_not_contains "$call_ref" \
  'typecheckSeq(VAL_STAR:SpectecTerminals, syn.instr)' \
  'call_ref retained target membership implied by val <: instr'

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
