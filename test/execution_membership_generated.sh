#!/bin/sh
set -eu

output=$1

grep -Fq \
  'op instr.local-get : SpectecTerminal ~> SpectecTerminal [ctor] .' \
  "$output"
grep -Fq \
  'cmb instr.local-get(LOCALIDX:SpectecTerminal) : SpectecTerminal' \
  "$output"
grep -Fq \
  'ceq typecheck(instr.local-get(LOCALIDX:SpectecTerminal), syn.instr) = true' \
  "$output"

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

if grep -A 1 -F 'crl [step-read-local-get]' "$output" \
    | grep -Fq 'typecheck'
then
  echo 'local.get retained a constructor-derived typecheck' >&2
  exit 1
fi

if grep -A 1 -F 'crl [step-pure-if-true]' "$output" \
    | grep -Fq 'typecheck'
then
  echo 'if retained an instr.const membership check' >&2
  exit 1
fi

if grep -A 1 -F 'crl [step-pure-select-true]' "$output" \
    | grep -Fq 'typecheck'
then
  echo 'select retained an instr.const membership check' >&2
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
  echo 'return_call_ref retained a frame-body typecheck' >&2
  exit 1
fi

if grep -A 1 -F 'crl [step-ctxt-label]' "$output" | grep -Fq 'typecheck'
then
  echo 'Step context retained a rewrite-result typecheck' >&2
  exit 1
fi

if grep -A 1 -F 'crl [step-ctxt-instrs]' "$output" | grep -Fq 'typecheck'
then
  echo 'Step value-prefix projection retained a duplicate typecheck' >&2
  exit 1
fi
