#!/bin/sh
set -eu

exe=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
root=$(CDPATH= cd -- "$2" && pwd)
output=/tmp/spec2maude-subtype-roundtrip-generated.maude
log=/tmp/spec2maude-subtype-roundtrip-generated.log

cd "$root"
rm -f "$output" "$log"
if ! perl -e '$SIG{ALRM}=sub { exit 124 }; alarm shift; exec @ARGV' \
  120 "$exe" translate -o "$output" >"$log" 2>&1
then
  cat "$log" >&2
  echo 'subtype round-trip translation failed' >&2
  exit 1
fi
grep -Eq '^\[spec2maude\] diagnostics: .*fatal=0 unsupported=0' "$log"

sequence_rule_count=0
direct_rule_count=0

statement_line () {
  awk -v head="[$1]" 'index($0, head) { print; exit }' "$output"
}

condition_line () {
  awk -v head="[$1]" 'index($0, head) { getline; print; exit }' "$output"
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

check_sequence_eliminated () {
  label=$1
  raw=$2
  statement=$(statement_line "$label")
  condition=$(condition_line "$label")
  require_contains "$statement" "[$label]" "$label generated rule is missing"
  require_contains "$statement" "$raw" "$label did not reuse its raw certified pattern"
  require_not_contains "$statement" 'helper.iter-map' "$label retained its direct reinjection map"
  require_not_contains "$condition" 'helper.subtype-' "$label retained an identity projection"
  require_contains "$condition" 'syn.val' "$label lost its source category guard"
  sequence_rule_count=$((sequence_rule_count + 1))
}

check_context_sequence_eliminated () {
  label=$1
  raw=$2
  statement=$(statement_line "$label")
  condition=$(condition_line "$label")
  require_contains "$statement" "[$label]" "$label generated rule is missing"
  require_contains "$statement" "$raw" "$label did not reuse its raw certified pattern"
  require_not_contains "$statement" 'helper.iter-map' "$label retained its direct reinjection map"
  require_not_contains "$condition" 'helper.subtype-' "$label retained an identity projection"
  require_contains "$condition" '_or_(_=/=_(VAL_STAR:SpectecTerminals, eps)' "$label lost its source progress condition"
  require_contains "$condition" 'typecheck(VAL_STAR:SpectecTerminals, syn.val)' "$label lost its source category guard"
  require_not_contains "$condition" 'typecheck(VAL_STAR:SpectecTerminals, syn.instr)' "$label retained target membership implied by val <: instr"
  require_not_contains "$condition" 'helper.context-' "$label retained a source-free context scanner"
  sequence_rule_count=$((sequence_rule_count + 1))
}

check_length_guard () {
  label=$1
  condition=$(condition_line "$label")
  require_contains "$condition" 'len(VAL' "$label lost its source length guard"
}

check_direct_eliminated () {
  label=$1
  shift
  statement=$(statement_line "$label")
  condition=$(condition_line "$label")
  require_contains "$statement" "[$label]" "$label generated rule is missing"
  require_not_contains "$statement" 'helper.subtype-inject' "$label retained its direct scalar reinjection"
  require_not_contains "$condition" 'helper.subtype-' "$label retained an identity projection"
  require_contains "$condition" 'syn.val' "$label lost its source category guard"
  direct_rule_count=$((direct_rule_count + 1))
}

check_identity_direct () {
  label=$1
  statement=$(statement_line "$label")
  condition=$(condition_line "$label")
  require_contains "$statement" "[$label]" "$label generated rule is missing"
  require_not_contains "$statement" 'helper.subtype-inject' "$label retained an identity injection"
  require_not_contains "$condition" 'helper.subtype-project.num' "$label retained an identity projection"
  direct_rule_count=$((direct_rule_count + 1))
}

check_null_scalar_eliminated () {
  label=$1
  raw=$2
  check_direct_eliminated \
    "$label"
  statement=$(statement_line "$label")
  condition=$(condition_line "$label")
  require_contains "$statement" "$raw" "$label did not reuse its raw certified pattern"
  require_contains "$condition" '_=/=_(VAL:SpectecTerminal, ref.ref-null-addr)' "$label stopped comparing the genuine source value"
}

check_sequence_eliminated step-pure-label-vals '=> VAL_STAR:SpectecTerminals'
check_sequence_eliminated step-pure-br-label-zero '=> VAL_STAR:SpectecTerminals INSTR_PRIME_STAR:SpectecTerminals'
check_sequence_eliminated step-pure-br-label-succ '=> VAL_STAR:SpectecTerminals instr.br'
check_sequence_eliminated step-pure-br-handler '=> VAL_STAR:SpectecTerminals instr.br'
check_sequence_eliminated step-pure-frame-vals '=> VAL_STAR:SpectecTerminals'
check_sequence_eliminated step-pure-return-frame '=> VAL_STAR:SpectecTerminals'
check_sequence_eliminated step-pure-return-label '=> VAL_STAR:SpectecTerminals instr.return'
check_sequence_eliminated step-pure-return-handler '=> VAL_STAR:SpectecTerminals instr.return'
check_sequence_eliminated step-pure-handler-vals '=> VAL_STAR:SpectecTerminals'
check_sequence_eliminated step-read-block 'eps, VAL_STAR:SpectecTerminals INSTR_STAR:SpectecTerminals'
check_sequence_eliminated step-read-loop 'VAL_STAR:SpectecTerminals INSTR_STAR:SpectecTerminals'
check_sequence_eliminated step-read-return-call-ref-label '=> VAL_STAR:SpectecTerminals instr.return-call-ref'
check_sequence_eliminated step-read-return-call-ref-handler '=> VAL_STAR:SpectecTerminals instr.return-call-ref'
check_sequence_eliminated step-read-return-call-ref-frame-addr '=> VAL_STAR:SpectecTerminals (ref.ref-func-addr'
check_sequence_eliminated step-read-try-table 'eps, VAL_STAR:SpectecTerminals INSTR_STAR:SpectecTerminals'
check_context_sequence_eliminated step-ctxt-instrs 'VAL_STAR:SpectecTerminals (INSTR_PRIME_STAR:SpectecTerminals INSTR_1_STAR:SpectecTerminals)'

# Pointwise projection preserves cardinality on its exact domain.  The raw
# target is reused while every source ListN guard remains present.
for label in \
  step-pure-br-label-zero \
  step-pure-frame-vals \
  step-pure-return-frame \
  step-read-block \
  step-read-loop \
  step-read-return-call-ref-frame-addr \
  step-read-try-table
do
  check_length_guard "$label"
done

check_direct_eliminated step-pure-select-true
check_direct_eliminated step-pure-select-false
check_null_scalar_eliminated \
  step-pure-br-on-null-addr \
  '=> VAL:SpectecTerminal'
check_null_scalar_eliminated \
  step-pure-br-on-non-null-addr \
  '=> VAL:SpectecTerminal instr.br'
check_direct_eliminated step-pure-local-tee

check_direct_eliminated step-read-table-fill-succ
check_identity_direct step-read-table-copy-le
check_identity_direct step-read-table-copy-gt
check_identity_direct step-read-table-init-succ
check_identity_direct step-read-load-pack-val

check_direct_eliminated step-read-memory-fill-succ
check_identity_direct step-read-memory-copy-le
check_identity_direct step-read-memory-copy-gt
check_identity_direct step-read-memory-init-succ
check_direct_eliminated step-read-array-fill-succ

check_identity_direct step-table-grow-succeed
check_identity_direct step-table-grow-fail
check_identity_direct step-memory-grow-succeed
check_identity_direct step-memory-grow-fail

if [ "$sequence_rule_count" -ne 16 ]; then
  echo "expected 16 audited sequence rules, found $sequence_rule_count" >&2
  exit 1
fi
if [ "$direct_rule_count" -ne 19 ]; then
  echo "expected 19 audited direct scalar/numeric rules, found $direct_rule_count" >&2
  exit 1
fi
if [ $((sequence_rule_count + direct_rule_count)) -ne 35 ]; then
  echo 'expected 35 audited generated rules' >&2
  exit 1
fi

if grep -Fq 'helper.subtype-' "$output"; then
  echo 'certified generated subtype identities retained helper materialization' >&2
  exit 1
fi

# These consumers require a genuine source value sequence, not its target
# instruction representation.
eval_statement=$(statement_line eval-expr-rule-1)
eval_condition=$(condition_line eval-expr-rule-1)
require_contains "$eval_statement" '[eval-expr-rule-1]' 'Eval_expr generated rule is missing'
require_contains "$eval_statement" 'seq(VAL_STAR:SpectecTerminals)' 'Eval_expr stopped returning direct source values'
require_contains "$eval_condition" 'typecheck(VAL_STAR:SpectecTerminals, syn.val)' 'Eval_expr lost its source membership guard'

frame_condition=$(condition_line step-read-call-ref-func)
require_contains "$frame_condition" 'rec.frame(helper.iter-map.step-read.2(VAL_STAR:SpectecTerminals)' 'frame locals stopped consuming genuine source values'

struct_condition=$(condition_line step-struct-new)
require_contains "$struct_condition" 'helper.iter-zip.step(VAL_STAR:SpectecTerminals' 'struct allocation stopped consuming genuine source values'

array_condition=$(condition_line step-array-new-fixed)
require_contains "$array_condition" 'helper.iter-map.step(VAL_STAR:SpectecTerminals' 'array allocation stopped consuming genuine source values'

# Repetition still uses its genuine source value directly after identity
# certification; only the independent count helper remains.
array_repeat_statement=$(statement_line step-pure-array-new)
array_repeat_condition=$(condition_line step-pure-array-new)
require_contains "$array_repeat_statement" 'helper.iter-count' 'scalar round-trip provenance leaked into a ListN repetition'
require_contains "$array_repeat_condition" 'typecheck(VAL:SpectecTerminal, syn.val)' 'ListN repetition lost its source guard'
require_not_contains "$array_repeat_condition" 'typecheck(VAL:SpectecTerminal, syn.instr)' 'ListN repetition retained target membership implied by val <: instr'
