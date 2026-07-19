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

step=$(condition_line 'crl [step-ctxt-instrs]')
require_before "$step" \
  '(_or_(_=/=_(VAL_STAR:SpectecTerminals, eps), _=/=_(INSTR_1_STAR:SpectecTerminals, eps))) = true' \
  'rel.step(config.sym(Z:SpectecTerminal, INSTR_STAR:SpectecTerminals)) =>' \
  'ctxt-instrs progress guard no longer precedes its self-recursive rewrite'

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
  'helper.iter-count.rolldt(N:SpectecTerminal, 0, N:SpectecTerminal, SUBTYPE_STAR:SpectecTerminals)' \
  'rolldt no longer passes its count as an immutable ListN capture'
require_before "$rolldt_conditions" \
  'rectype.rec(list.wrap(SUBTYPE_STAR:SpectecTerminals)) := def.rollrt(X:SpectecTerminal, RECTYPE:SpectecTerminal)' \
  'N:SpectecTerminal := len(SUBTYPE_STAR:SpectecTerminals)' \
  'rolldt no longer derives its caller count after binding the source subtype sequence'

rolldt_step=$(matching_line 'ceq helper.iter-count.rolldt(s COUNT1:Nat')
rolldt_step_conditions=$(condition_line 'ceq helper.iter-count.rolldt(s COUNT1:Nat')
require_contains "$rolldt_step" \
  'helper.iter-count.rolldt(s COUNT1:Nat, I:Nat, N:Nat, SUBTYPE_STAR:SpectecTerminals) = OUTPUT1:SpectecTerminal helper.iter-count.rolldt(COUNT1:Nat, s I:Nat, N:Nat, SUBTYPE_STAR:SpectecTerminals)' \
  'rolldt helper no longer decrements the work count, increments the index, and preserves its original captures'
require_contains "$rolldt_step_conditions" \
  'N:Nat = len(SUBTYPE_STAR:SpectecTerminals)' \
  'rolldt helper no longer checks the immutable original count against the original subtype sequence'
