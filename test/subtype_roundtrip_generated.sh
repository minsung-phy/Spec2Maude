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
  require_contains "$statement" "$raw" "$label did not reuse its raw certified pattern"
  require_not_contains "$statement" 'helper.iter-map' "$label retained its direct reinjection map"
  require_contains "$condition" ':= helper.subtype-project-seq.' "$label lost its exact image-domain guard"
  sequence_rule_count=$((sequence_rule_count + 1))
}

check_context_sequence_eliminated () {
  label=$1
  raw=$2
  statement=$(statement_line "$label")
  condition=$(condition_line "$label")
  require_contains "$statement" "$raw" "$label did not reuse its raw certified pattern"
  require_not_contains "$statement" 'helper.iter-map' "$label retained its direct reinjection map"
  require_contains "$condition" 'helper.context-split.step' "$label lost its certified context split"
  require_not_contains "$condition" ':= helper.subtype-project-seq.' "$label repeated the projection proved by its context split"
  require_not_contains "$condition" '_or_(_=/=_(' "$label repeated the progress guard proved by its strict context split"
  sequence_rule_count=$((sequence_rule_count + 1))
}

check_length_guard () {
  label=$1
  condition=$(condition_line "$label")
  require_contains "$condition" 'len(VAL_STAR:SpectecTerminals)' "$label lost its source length guard"
}

check_direct_eliminated () {
  label=$1
  shift
  statement=$(statement_line "$label")
  condition=$(condition_line "$label")
  require_not_contains "$statement" 'helper.subtype-inject' "$label retained its direct scalar reinjection"
  for evidence in "$@"
  do
    require_contains "$condition" "$evidence" "$label lost its exact scalar image-domain guard"
  done
  direct_rule_count=$((direct_rule_count + 1))
}

check_null_scalar_eliminated () {
  label=$1
  raw=$2
  check_direct_eliminated \
    "$label" \
    'helper.subtype-project.step-pure(PATTERN1:SpectecTerminal)'
  statement=$(statement_line "$label")
  condition=$(condition_line "$label")
  require_contains "$statement" "$raw" "$label did not reuse its raw certified pattern"
  require_contains "$condition" '_=/=_(VAL:SpectecTerminal, ref.ref-null-addr)' "$label stopped comparing the genuine projected source value"
}

check_sequence_eliminated step-pure-label-vals '=> PATTERN1:SpectecTerminals'
check_sequence_eliminated step-pure-br-label-zero '=> PATTERN2:SpectecTerminals INSTR_PRIME_STAR:SpectecTerminals'
check_sequence_eliminated step-pure-br-label-succ '=> PATTERN1:SpectecTerminals instr.br'
check_sequence_eliminated step-pure-br-handler '=> PATTERN1:SpectecTerminals instr.br'
check_sequence_eliminated step-pure-frame-vals '=> PATTERN1:SpectecTerminals'
check_sequence_eliminated step-pure-return-frame '=> PATTERN2:SpectecTerminals'
check_sequence_eliminated step-pure-return-label '=> PATTERN1:SpectecTerminals instr.return'
check_sequence_eliminated step-pure-return-handler '=> PATTERN1:SpectecTerminals instr.return'
check_sequence_eliminated step-pure-handler-vals '=> PATTERN1:SpectecTerminals'
check_sequence_eliminated step-read-block 'eps, PATTERN1:SpectecTerminals INSTR_STAR:SpectecTerminals'
check_sequence_eliminated step-read-loop 'PATTERN1:SpectecTerminals INSTR_STAR:SpectecTerminals'
check_sequence_eliminated step-read-return-call-ref-label '=> PATTERN1:SpectecTerminals instr.return-call-ref'
check_sequence_eliminated step-read-return-call-ref-handler '=> PATTERN1:SpectecTerminals instr.return-call-ref'
check_sequence_eliminated step-read-return-call-ref-frame-addr '=> PATTERN2:SpectecTerminals (ref.ref-func-addr'
check_sequence_eliminated step-read-try-table 'eps, PATTERN1:SpectecTerminals INSTR_STAR:SpectecTerminals'
check_context_sequence_eliminated step-ctxt-instrs 'PATTERN1:SpectecTerminals (INSTR_PRIME_STAR:SpectecTerminals INSTR_1_STAR:SpectecTerminals)'

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

check_direct_eliminated \
  step-pure-select-true \
  'helper.subtype-project.step-pure(PATTERN1:SpectecTerminal)'
check_direct_eliminated \
  step-pure-select-false \
  'helper.subtype-project.step-pure(PATTERN2:SpectecTerminal)'
check_null_scalar_eliminated \
  step-pure-br-on-null-addr \
  '=> PATTERN1:SpectecTerminal'
check_null_scalar_eliminated \
  step-pure-br-on-non-null-addr \
  '=> PATTERN1:SpectecTerminal instr.br'
check_direct_eliminated \
  step-pure-local-tee \
  'helper.subtype-project.step-pure(PATTERN1:SpectecTerminal)'

check_direct_eliminated \
  step-read-table-fill-succ \
  'helper.subtype-project.step-pure(PATTERN2:SpectecTerminal)' \
  'helper.subtype-project.num(PATTERN3:SpectecTerminal)'
check_direct_eliminated \
  step-read-table-copy-le \
  'helper.subtype-project.num(PATTERN1:SpectecTerminal)' \
  'helper.subtype-project.num(PATTERN2:SpectecTerminal)' \
  'helper.subtype-project.num(PATTERN3:SpectecTerminal)'
check_direct_eliminated \
  step-read-table-copy-gt \
  'helper.subtype-project.num(PATTERN1:SpectecTerminal)' \
  'helper.subtype-project.num(PATTERN2:SpectecTerminal)' \
  'helper.subtype-project.num(PATTERN3:SpectecTerminal)'
check_direct_eliminated \
  step-read-table-init-succ \
  'helper.subtype-project.num(PATTERN1:SpectecTerminal)'
check_direct_eliminated \
  step-read-load-pack-val \
  'helper.subtype-project.num(PATTERN2:SpectecTerminal)'

check_direct_eliminated \
  step-read-memory-fill-succ \
  'helper.subtype-project.step-pure(PATTERN2:SpectecTerminal)' \
  'helper.subtype-project.num(PATTERN3:SpectecTerminal)'
check_direct_eliminated \
  step-read-memory-copy-le \
  'helper.subtype-project.num(PATTERN1:SpectecTerminal)' \
  'helper.subtype-project.num(PATTERN2:SpectecTerminal)' \
  'helper.subtype-project.num(PATTERN3:SpectecTerminal)'
check_direct_eliminated \
  step-read-memory-copy-gt \
  'helper.subtype-project.num(PATTERN1:SpectecTerminal)' \
  'helper.subtype-project.num(PATTERN2:SpectecTerminal)' \
  'helper.subtype-project.num(PATTERN3:SpectecTerminal)'
check_direct_eliminated \
  step-read-memory-init-succ \
  'helper.subtype-project.num(PATTERN1:SpectecTerminal)'
check_direct_eliminated \
  step-read-array-fill-succ \
  'helper.subtype-project.step-pure(PATTERN1:SpectecTerminal)'

check_direct_eliminated \
  step-table-grow-succeed \
  'helper.subtype-project.num(PATTERN1:SpectecTerminal)'
check_direct_eliminated \
  step-table-grow-fail \
  'helper.subtype-project.num(PATTERN1:SpectecTerminal)'
check_direct_eliminated \
  step-memory-grow-succeed \
  'helper.subtype-project.num(PATTERN1:SpectecTerminal)'
check_direct_eliminated \
  step-memory-grow-fail \
  'helper.subtype-project.num(PATTERN1:SpectecTerminal)'

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

# The remaining RHS injections consume genuine source values obtained from
# state, rather than reinjecting a source-pattern projection.  Count rule
# labels, not the number of helper calls within each rule.
rhs_injection_labels=$(awk '
  /^  crl \[/ && /=>/ && /helper\.subtype-inject/ {
    label=$0
    sub(/^.*\[/, "", label)
    sub(/\].*$/, "", label)
    print label
  }
' "$output")
rhs_injection_rule_count=$(printf '%s\n' "$rhs_injection_labels" | awk 'NF { count++ } END { print count + 0 }')
if [ "$rhs_injection_rule_count" -ne 6 ]; then
  echo "expected 6 genuine-source RHS injection rules, found $rhs_injection_rule_count" >&2
  exit 1
fi
for label in \
  step-read-local-get \
  step-read-global-get \
  step-read-table-size \
  step-read-memory-size \
  step-read-struct-get-struct \
  step-read-array-get-array
do
  if ! printf '%s\n' "$rhs_injection_labels" | grep -Fxq "$label"; then
    echo "$label genuine-source RHS injection unexpectedly disappeared" >&2
    exit 1
  fi
done

# These consumers require a genuine source value sequence, not its target
# instruction representation.
eval_statement=$(statement_line eval-expr-rule-1)
eval_condition=$(condition_line eval-expr-rule-1)
require_contains "$eval_statement" 'seq(VAL_STAR:SpectecTerminals)' 'Eval_expr stopped returning projected source values'
require_contains "$eval_condition" 'VAL_STAR:SpectecTerminals := helper.subtype-project-seq.' 'Eval_expr lost its source projection'

frame_condition=$(condition_line step-read-call-ref-func)
require_contains "$frame_condition" 'rec.frame(helper.iter-map.step-read' 'frame locals stopped consuming genuine source values'

struct_condition=$(condition_line step-struct-new)
require_contains "$struct_condition" 'helper.iter-zip.step(VAL_STAR:SpectecTerminals' 'struct allocation stopped consuming genuine source values'

array_condition=$(condition_line step-array-new-fixed)
require_contains "$array_condition" 'helper.iter-map.step(VAL_STAR:SpectecTerminals' 'array allocation stopped consuming genuine source values'

# A scalar projection may not escape into an enclosing repetition: this case
# repeats the genuine source value and therefore keeps its source-driven helper.
array_repeat_statement=$(statement_line step-pure-array-new)
array_repeat_condition=$(condition_line step-pure-array-new)
require_contains "$array_repeat_statement" 'helper.iter-count' 'scalar round-trip provenance leaked into a ListN repetition'
require_contains "$array_repeat_condition" 'VAL:SpectecTerminal := helper.subtype-project.' 'ListN repetition lost its genuine source projection'
