#!/bin/sh
set -eu

exe=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
root=$(CDPATH= cd -- "$2" && pwd)
output=/tmp/spec2maude-execution-context.maude
translate_log=/tmp/spec2maude-execution-context-translate.log
maude_log=/tmp/spec2maude-execution-context-maude.log

cd "$root"
if ! perl -e '$SIG{ALRM}=sub { exit 124 }; alarm shift; exec @ARGV' \
  120 "$exe" translate -o "$output" >"$translate_log" 2>&1
then
  cat "$translate_log" >&2
  echo 'execution-context translation failed' >&2
  exit 1
fi
grep -Eq '^\[spec2maude\] diagnostics: .*fatal=0 unsupported=0' "$translate_log"

statement=$(awk '/crl \[step-ctxt-instrs\]/ { print; exit }' "$output")
condition=$(awk '/crl \[step-ctxt-instrs\]/ { getline; print; exit }' "$output")
call_condition=$(awk '/crl \[step-read-call-ref-func\]/ { getline; print; exit }' "$output")

test "$(grep -c 'crl \[step-ctxt-instrs\]' "$output")" -eq 1

context_line=$(grep -n 'crl \[step-ctxt-instrs\]' "$output" | cut -d: -f1)
for label in step-pure step-read step-local-set step-store-num-val
do
  direct_line=$(grep -n "crl \[$label\]" "$output" | cut -d: -f1)
  if test "$direct_line" -ge "$context_line"; then
    echo "direct Step rule was emitted after the associative context rule: $label" >&2
    exit 1
  fi
done

printf '%s\n' "$statement" | grep -Fq \
  'rel.step(config.sym(Z:SpectecTerminal, STREAM1:SpectecTerminals))'
printf '%s\n' "$statement" | grep -Fq \
  'PATTERN1:SpectecTerminals (INSTR_PRIME_STAR:SpectecTerminals INSTR_1_STAR:SpectecTerminals)'

printf '%s\n' "$condition" | grep -Fq \
  'helper.context-split.step(STREAM1:SpectecTerminals) => helper.context-split-result.step(PATTERN1:SpectecTerminals, INSTR_STAR:SpectecTerminals, INSTR_1_STAR:SpectecTerminals)'
if printf '%s\n' "$condition" \
     | grep -Eq 'helper\.subtype-project-seq\.step-pure|_or_\(_=/=_\(VAL_STAR'
then
  echo 'Step context retained projection/progress certified by its strict split helper' >&2
  exit 1
fi
printf '%s\n' "$condition" | grep -Fq \
  'rel.step(config.sym(Z:SpectecTerminal, INSTR_STAR:SpectecTerminals)) => config.sym(Z_PRIME:SpectecTerminal, INSTR_PRIME_STAR:SpectecTerminals)'
printf '%s\n' "$condition" | grep -Fq \
  'typecheck(config.sym(Z_PRIME:SpectecTerminal, INSTR_PRIME_STAR:SpectecTerminals), syn.config)'
if printf '%s\n' "$condition" \
     | grep -Eq 'syn\.state\)|typecheckSeq\('; then
  echo 'Step/ctxt-instrs retained payload validation implied by its whole config guard' >&2
  exit 1
fi

printf '%s\n' "$call_condition" | grep -Fq \
  'RESULT1:SpectecTerminal := rel.expand(value('
printf '%s\n' "$call_condition" | grep -Fq \
  'func.func(X:SpectecTerminal, PATTERN2:SpectecTerminals, INSTR_STAR:SpectecTerminals) := value('
if printf '%s\n' "$call_condition" \
     | grep -Eq 'typecheck\([^)]*, syn\.(comptype|funccode)\)'; then
  echo 'call-ref retained whole-result validation implied by a typed producer' >&2
  exit 1
fi

for label in \
  cursor-start index-start non-value-result-prefix non-value-result-suffix \
  non-value-pop non-value-extend-one non-value-extend \
  index-result-prefix index-result-suffix index-prefix index-end
do
  grep -Fq "[helper-context-split-step-$label]" "$output"
done
for label in \
  pick-current pick-previous bounded index-all-values-start \
  index-value-fallback index-value-result index-value-end index-value-prefix
do
  if grep -Fq "[helper-context-split-step-$label]" "$output"; then
    echo "Step context retained a candidate family excluded by its irreducibility certificate: $label" >&2
    exit 1
  fi
done
if grep -Fq 'helper.context-scan-index-values.step' "$output"; then
  echo 'Step context retained its value-only candidate state despite the irreducibility certificate' >&2
  exit 1
fi
grep -Fq \
  'helper.context-split-result.step(STREAM7:SpectecTerminals, STREAM8:SpectecTerminals, STREAM4:SpectecTerminals)' \
  "$output"
grep -Fq \
  'helper.context-split-result.step(takeRun(s COUNT2:Nat, STREAM1:SpectecTerminals), slice(STREAM1:SpectecTerminals, s COUNT2:Nat, _-_(COUNT3:Nat, s COUNT2:Nat)), drop(COUNT3:Nat, STREAM1:SpectecTerminals))' \
  "$output"
grep -Fq \
  'helper.context-split-result.step(takeRun(0, STREAM1:SpectecTerminals), slice(STREAM1:SpectecTerminals, 0, _-_(COUNT3:Nat, 0)), drop(COUNT3:Nat, STREAM1:SpectecTerminals))' \
  "$output"
grep -Fq \
  'helper.context-dispatch.step(STREAM1:SpectecTerminals, helper.context-has-compact.step(STREAM1:SpectecTerminals))' \
  "$output"
grep -Fq \
  'op helper.context-scan-value.step : SpectecTerminal SpectecTerminals SpectecTerminals ContextStackStep Bool -> ContextSplitStep' \
  "$output"
grep -Fq \
  'helper.context-scan-value.step(VALUE1:SpectecTerminal, STREAM2:SpectecTerminals, STREAM3:SpectecTerminals, HISTORY1:ContextStackStep, helper.context-is-value.step(VALUE1:SpectecTerminal))' \
  "$output"
test "$(grep -c 'helper.context-is-value.step(VALUE1:SpectecTerminal))' "$output")" -eq 2
grep -Fq \
  'helper.context-scan-value.step(VALUE1:SpectecTerminal, STREAM2:SpectecTerminals, STREAM3:SpectecTerminals, HISTORY1:ContextStackStep, true)' \
  "$output"
grep -Fq \
  'helper.context-scan-value.step(VALUE1:SpectecTerminal, STREAM2:SpectecTerminals, STREAM3:SpectecTerminals, HISTORY1:ContextStackStep, false)' \
  "$output"
grep -Fq \
  'helper.context-first-defined.step(STREAM1:SpectecTerminals, COUNT4:Nat, COUNT1:Nat, _<_(COUNT1:Nat, COUNT4:Nat))' \
  "$output"
grep -Fq \
  'helper.context-first-defined.step(STREAM1:SpectecTerminals, COUNT4:Nat, COUNT1:Nat, true) = helper.context-first-value.step(STREAM1:SpectecTerminals, COUNT4:Nat, COUNT1:Nat, helper.context-is-value.step(index(STREAM1:SpectecTerminals, COUNT1:Nat)))' \
  "$output"
grep -Fq \
  'helper.context-first-defined.step(STREAM1:SpectecTerminals, COUNT4:Nat, COUNT1:Nat, false) = helper.context-no-focus.step' \
  "$output"
grep -Fq \
  'helper.subtype-project-seq.step-pure(runSeq(COUNT1:Nat, instr.const' \
  "$output"

printf '%s\n' \
  'select SPEC2MAUDE-GENERATED .' \
  'search helper.context-split.step(instr.const(numtype.i32, uN.wrap(0)) instr.const(numtype.i32, uN.wrap(1)) instr.nop instr.drop) =>* helper.context-split-result.step(P:SpectecTerminals, FOCUS:SpectecTerminals, SUFFIX:SpectecTerminals) .' \
  'search [1] helper.context-split.step(instr.const(numtype.i32, uN.wrap(0)) instr.const(numtype.i32, uN.wrap(1)) instr.nop instr.drop) =>* helper.context-split-result.step(eps, instr.const(numtype.i32, uN.wrap(0)) instr.const(numtype.i32, uN.wrap(1)) instr.nop instr.drop, eps) .' \
  'search [1] helper.context-split.step(runSeq(1024, instr.const(numtype.i32, uN.wrap(0))) instr.nop instr.drop) =>* helper.context-split-result.step(runSeq(1024, instr.const(numtype.i32, uN.wrap(0))), instr.nop, instr.drop) .' \
  'search [1] helper.context-split.step(runSeq(2, instr.const(numtype.i32, uN.wrap(0))) instr.nop) =>* helper.context-split-result.step(eps, runSeq(2, instr.const(numtype.i32, uN.wrap(0))) instr.nop, eps) .' \
  'search [1] helper.context-split.step(instr.const(numtype.i32, uN.wrap(0)) instr.trap instr.nop instr.drop) =>* helper.context-split-result.step(instr.const(numtype.i32, uN.wrap(0)), instr.trap instr.nop, instr.drop) .' \
  'search [1] helper.context-split.step(runSeq(4, instr.const(numtype.i32, uN.wrap(0)))) =>* helper.context-split-result.step(P:SpectecTerminals, F:SpectecTerminals, S:SpectecTerminals) .' \
  'search [1] rel.step(config.sym(state.sym(rec.store(eps, eps, eps, eps, eps, eps, eps, eps, eps, eps), rec.frame(eps, rec.moduleinst(eps, eps, eps, eps, eps, eps, eps, eps, eps))), runSeq(1, instr.const(numtype.i32, uN.wrap(0))) instr.const(numtype.i32, uN.wrap(0)) instr.binop(numtype.i32, binop.add))) =>1 config.sym(state.sym(rec.store(eps, eps, eps, eps, eps, eps, eps, eps, eps, eps), rec.frame(eps, rec.moduleinst(eps, eps, eps, eps, eps, eps, eps, eps, eps))), instr.const(numtype.i32, uN.wrap(0))) .' \
  'search [1] rel.step(config.sym(state.sym(rec.store(eps, eps, eps, eps, eps, eps, eps, eps, eps, eps), rec.frame(eps, rec.moduleinst(eps, eps, eps, eps, eps, eps, eps, eps, eps))), canonicalRun(2, instr.const(numtype.i32, uN.wrap(5))) instr.const(numtype.i32, uN.wrap(1)) instr.select(eps))) =>1 config.sym(state.sym(rec.store(eps, eps, eps, eps, eps, eps, eps, eps, eps, eps), rec.frame(eps, rec.moduleinst(eps, eps, eps, eps, eps, eps, eps, eps, eps))), instr.const(numtype.i32, uN.wrap(5))) .' \
  'quit' \
  | maude -no-banner "$output" >"$maude_log" 2>&1

if grep -Eq 'Warning:|Advisory:|Error:' "$maude_log"; then
  cat "$maude_log" >&2
  exit 1
fi
test "$(grep -c 'Solution 1' "$maude_log")" -eq 5
test "$(grep -c 'No solution' "$maude_log")" -eq 3
test "$(grep -c '^Solution 5 ' "$maude_log")" -eq 1
test "$(grep -c '^Solution 6 ' "$maude_log")" -eq 0
