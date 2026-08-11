#!/bin/sh
set -eu

if [ "$#" -eq 1 ]; then
  output=$1
elif [ "$#" -eq 2 ]; then
  exe=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
  root=$(CDPATH= cd -- "$2" && pwd)
  output=/tmp/spec2maude-execution-membership.maude
  translate_log=/tmp/spec2maude-execution-membership-translate.log
  cd "$root"
  rm -f "$output" "$translate_log"
  if ! perl -e '$SIG{ALRM}=sub { exit 124 }; alarm shift; exec @ARGV' \
    120 "$exe" translate -o "$output" >"$translate_log" 2>&1
  then
    cat "$translate_log" >&2
    echo 'execution-membership translation failed' >&2
    exit 1
  fi
  grep -Eq '^\[spec2maude\] diagnostics: .*fatal=0 unsupported=0' "$translate_log"
else
  echo "usage: $0 OUTPUT | SPEC2MAUDE WORKSPACE_ROOT" >&2
  exit 2
fi

require_rule () {
  label=$1
  if ! grep -Fq "[$label] :" "$output"; then
    echo "missing generated rule $label" >&2
    exit 1
  fi
}

line_number () {
  text=$1
  grep -n -F -m 1 "$text" "$output" | cut -d: -f1
}

pattern_line_number () {
  pattern=$1
  grep -n -E -m 1 "$pattern" "$output" | cut -d: -f1
}

require_before () {
  first=$1
  second=$2
  message=$3
  first_line=$(line_number "$first")
  second_line=$(line_number "$second")
  if [ -z "$first_line" ] || [ -z "$second_line" ] \
      || [ "$first_line" -ge "$second_line" ]; then
    echo "$message" >&2
    exit 1
  fi
}

require_before_pattern () {
  first=$1
  second=$2
  message=$3
  first_line=$(line_number "$first")
  second_line=$(pattern_line_number "$second")
  if [ -z "$first_line" ] || [ -z "$second_line" ] \
      || [ "$first_line" -ge "$second_line" ]; then
    echo "$message" >&2
    exit 1
  fi
}

grep -Fq \
  'op instr.local-get : SpectecTerminal ~> SpectecTerminal [ctor] .' \
  "$output"
grep -Fq \
  'cmb instr.local-get(LOCALIDX:SpectecTerminal) : SpectecTerminal' \
  "$output"
grep -Fq \
  'ceq typecheck(instr.local-get(LOCALIDX:SpectecTerminal), syn.instr) = true' \
  "$output"
require_before_pattern \
  'ceq typecheck(instr.local-get(LOCALIDX:SpectecTerminal), syn.instr) = true' \
  'TypD-instr/.*/VariantT\[[0-9]+\]/category-union / typcase' \
  'syn.instr checks an inherited reference category before its own constructors'
require_before_pattern \
  'ceq typecheck(instr.local-get(LOCALIDX:SpectecTerminal), syn.instr) = true' \
  'TypD-instr/.*/VariantT/subtype/.* / category-inclusion' \
  'syn.instr checks an inherited value category before its own constructors'

grep -Fq \
  'rl [step-pure-unreachable] : rel.step-pure(instr.unreachable) => instr.trap .' \
  "$output"
grep -Fq \
  'rl [step-pure-nop] : rel.step-pure(instr.nop) => eps .' \
  "$output"
grep -Fq \
  'VAL:SpectecTerminal := def.local(Z:SpectecTerminal, X:SpectecTerminal)' \
  "$output"
grep -Fq \
  '_=/=_(proj.uN.wrap.0(C:SpectecTerminal), 0)' \
  "$output"

require_rule step-read-local-get
if grep -A 1 -F 'crl [step-read-local-get]' "$output" \
    | grep -Fq 'typecheck(X:SpectecTerminal, syn.localidx)'
then
  echo 'local.get repeated a payload typecheck already enforced by constructor membership' >&2
  exit 1
fi

require_rule step-pure-if-true
if grep -A 1 -F 'crl [step-pure-if-true]' "$output" \
    | grep -Fq 'typecheck(BT:SpectecTerminal, syn.blocktype)'
then
  echo 'if repeated a blocktype check already enforced by constructor membership' >&2
  exit 1
fi

if ! grep -A 1 -F 'crl [step-pure-select-true]' "$output" \
    | grep -Fq 'typecheck(C:SpectecTerminal, syn.num(numtype.i32))'
then
  echo 'select lost its dependent constant payload check' >&2
  exit 1
fi

if ! grep -A 1 -F 'crl [helper-truth-worklist-step-read-prove-14]' "$output" \
    | grep -Fq 'typecheck(TYPEIDX:SpectecTerminal, syn.typeidx)'
then
  echo 'runtime truth incorrectly dropped a constructor payload guard' >&2
  exit 1
fi

if ! grep -A 1 -F 'crl [step-pure-ref-is-null-false]' "$output" \
    | grep -Fq 'typecheck(REF:SpectecTerminal, syn.ref)'
then
  echo 'ref.is_null lost the category guard on its bare value pattern' >&2
  exit 1
fi

if grep -A 1 -F 'crl [step-read-return-call-ref-frame-addr]' "$output" \
    | grep -Fq 'typecheckSeq((((PATTERN1'
then
  echo 'return_call_ref repeated a frame-body check already enforced by constructor membership' >&2
  exit 1
fi

if ! grep -A 1 -F 'crl [step-read-return-call-ref-frame-addr]' "$output" \
    | grep -Fq 'VAL_PRIME_STAR:SpectecTerminals := helper.subtype-project-seq.step-pure'
then
  echo 'return_call_ref lost its value-prefix witness projection' >&2
  exit 1
fi

for label in step-ctxt-instrs step-ctxt-label step-ctxt-handler; do
  conditions=$(grep -A 1 -F "crl [$label]" "$output")
  if ! printf '%s\n' "$conditions" | grep -Fq ', syn.config)'; then
    echo "$label lost its whole rewrite-result config guard" >&2
    exit 1
  fi
  if printf '%s\n' "$conditions" \
      | grep -Eq 'syn\.state\)|typecheckSeq\('; then
    echo "$label retained a payload check implied by its whole config guard" >&2
    exit 1
  fi
done

frame_conditions=$(grep -A 1 -F 'crl [step-ctxt-frame]' "$output")
if ! printf '%s\n' "$frame_conditions" | grep -Fq ', syn.config)'; then
  echo 'step-ctxt-frame lost its whole rewrite-result config guard' >&2
  exit 1
fi
if printf '%s\n' "$frame_conditions" \
    | grep -Eq 'syn\.(store|frame|state)\)|typecheckSeq\('; then
  echo 'step-ctxt-frame retained a nested payload check implied by its whole config guard' >&2
  exit 1
fi

maude_log=/tmp/spec2maude-execution-membership-maude.log
printf '%s\n' \
  'select SPEC2MAUDE-GENERATED .' \
  'red typecheck(instr.local-get(uN.wrap(0)), syn.instr) .' \
  'red typecheck(ref.ref-null-addr, syn.instr) .' \
  'red typecheck(bool(true), syn.instr) .' \
  'quit' \
  | maude -no-banner "$output" >"$maude_log" 2>&1

if grep -Eq 'Warning:|Advisory:|Error:' "$maude_log"; then
  cat "$maude_log" >&2
  exit 1
fi
test "$(grep -c 'result Bool: true' "$maude_log")" -eq 2
test "$(grep -c 'result Bool: false' "$maude_log")" -eq 1
