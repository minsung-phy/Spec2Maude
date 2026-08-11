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
  'PATTERN1:SpectecTerminals (INSTR_STAR:SpectecTerminals INSTR_1_STAR:SpectecTerminals)'
printf '%s\n' "$statement" | grep -Fq \
  'PATTERN1:SpectecTerminals (INSTR_PRIME_STAR:SpectecTerminals INSTR_1_STAR:SpectecTerminals)'

projection='VAL_STAR:SpectecTerminals := helper.subtype-project-seq.step-pure(PATTERN1:SpectecTerminals)'
progress='_or_(_=/=_(VAL_STAR:SpectecTerminals, eps), _=/=_(INSTR_1_STAR:SpectecTerminals, eps))'
recursive='rel.step(config.sym(Z:SpectecTerminal, INSTR_STAR:SpectecTerminals)) => config.sym(Z_PRIME:SpectecTerminal, INSTR_PRIME_STAR:SpectecTerminals)'
result_guard='typecheck(config.sym(Z_PRIME:SpectecTerminal, INSTR_PRIME_STAR:SpectecTerminals), syn.config)'

for required in "$projection" "$progress" "$recursive" "$result_guard"
do
  printf '%s\n' "$condition" | grep -Fq "$required"
done

printf '%s\n' "$condition" | awk \
  -v projection="$projection" -v progress="$progress" -v recursive="$recursive" '
    {
      m = index($0, projection)
      p = index($0, progress)
      r = index($0, recursive)
    }
    END { exit !(m > 0 && p > m && r > p) }
  '

if grep -Eq 'helper\.context-|Context(Split|Stack|MaybeFocus)' "$output"; then
  echo 'source-free context scanner survived generic context lowering' >&2
  exit 1
fi
if printf '%s\n' "$statement" | grep -Fq 'helper.iter-map'; then
  echo 'Step/ctxt-instrs failed to reuse its raw instruction prefix' >&2
  exit 1
fi
if grep -Eq 'ceq typecheck\(instr\.(v)?const.*syn\.val\)' "$output"; then
  echo 'instruction constructors were globally admitted as source values' >&2
  exit 1
fi

printf '%s\n' \
  'select SPEC2MAUDE-GENERATED .' \
  'red typecheck(num.const(numtype.i32, uN.wrap(1)), syn.val) .' \
  'red typecheck(instr.const(numtype.i32, uN.wrap(1)), syn.val) .' \
  'red typecheck(rec.frame(seq(num.const(numtype.i32, uN.wrap(1))), rec.moduleinst(eps, eps, eps, eps, eps, eps, eps, eps, eps)), syn.frame) .' \
  'red typecheck(rec.frame(seq(instr.const(numtype.i32, uN.wrap(1))), rec.moduleinst(eps, eps, eps, eps, eps, eps, eps, eps, eps)), syn.frame) .' \
  'search [1] rel.step(config.sym(state.sym(rec.store(eps, eps, eps, eps, eps, eps, eps, eps, eps, eps), rec.frame(eps, rec.moduleinst(eps, eps, eps, eps, eps, eps, eps, eps, eps))), instr.const(numtype.i32, uN.wrap(7)) instr.const(numtype.i32, uN.wrap(1)) instr.const(numtype.i32, uN.wrap(2)) instr.binop(numtype.i32, binop.add))) =>1 config.sym(state.sym(rec.store(eps, eps, eps, eps, eps, eps, eps, eps, eps, eps), rec.frame(eps, rec.moduleinst(eps, eps, eps, eps, eps, eps, eps, eps, eps))), instr.const(numtype.i32, uN.wrap(7)) instr.const(numtype.i32, uN.wrap(3))) .' \
  'quit' \
  | maude -no-banner "$output" >"$maude_log" 2>&1

if grep -Eq 'Warning:|Advisory:|Error:' "$maude_log"; then
  cat "$maude_log" >&2
  exit 1
fi
test "$(grep -c 'result Bool: true' "$maude_log")" -eq 2
test "$(grep -c 'result Bool: false' "$maude_log")" -eq 2
test "$(grep -c 'Solution 1' "$maude_log")" -eq 1
