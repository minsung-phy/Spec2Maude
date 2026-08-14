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
  'VAL_STAR:SpectecTerminals (INSTR_STAR:SpectecTerminals INSTR_1_STAR:SpectecTerminals)'
printf '%s\n' "$statement" | grep -Fq \
  'VAL_STAR:SpectecTerminals (INSTR_PRIME_STAR:SpectecTerminals INSTR_1_STAR:SpectecTerminals)'

source_guard='typecheck(VAL_STAR:SpectecTerminals, syn.val)'
progress='_or_(_=/=_(VAL_STAR:SpectecTerminals, eps), _=/=_(INSTR_1_STAR:SpectecTerminals, eps))'
recursive='rel.step(config.sym(Z:SpectecTerminal, INSTR_STAR:SpectecTerminals)) => config.sym(Z_PRIME:SpectecTerminal, INSTR_PRIME_STAR:SpectecTerminals)'
for required in "$source_guard" "$progress" "$recursive"
do
  printf '%s\n' "$condition" | grep -Fq "$required"
done

if printf '%s\n' "$condition" | grep -Fq 'typecheck(config.sym(Z_PRIME:SpectecTerminal, INSTR_PRIME_STAR:SpectecTerminals), syn.config)'; then
  echo 'Step/ctxt-instrs repeated the certified recursive Step result typecheck' >&2
  exit 1
fi

printf '%s\n' "$condition" | awk \
  -v progress="$progress" -v recursive="$recursive" \
  -v source_guard="$source_guard" '
    {
      m = index($0, source_guard)
      p = index($0, progress)
      r = index($0, recursive)
    }
    END { exit !(p > 0 && m > p && r > m) }
  '

if printf '%s\n' "$condition" | grep -Fq 'typecheck(VAL_STAR:SpectecTerminals, syn.instr)'; then
  echo 'Step/ctxt-instrs retained target membership implied by val <: instr' >&2
  exit 1
fi

if grep -Eq 'helper\.context-|Context(Split|Stack|MaybeFocus)' "$output"; then
  echo 'source-free context scanner survived generic context lowering' >&2
  exit 1
fi
if printf '%s\n' "$statement" | grep -Fq 'helper.iter-map'; then
  echo 'Step/ctxt-instrs failed to reuse its raw instruction prefix' >&2
  exit 1
fi
if printf '%s\n%s\n' "$statement" "$condition" | grep -Fq 'helper.subtype-'; then
  echo 'Step/ctxt-instrs retained an identity subtype helper' >&2
  exit 1
fi

printf '%s\n' \
  'select SPEC2MAUDE-GENERATED .' \
  'red typecheck(const(i32, uN.wrap(1)), syn.val) .' \
  'red typecheck(instr.binop(i32, binop.add), syn.val) .' \
  'red typecheck(rec.frame(seq(const(i32, uN.wrap(1))), rec.moduleinst(eps, eps, eps, eps, eps, eps, eps, eps, eps)), syn.frame) .' \
  'red typecheck(rec.frame(seq(instr.binop(i32, binop.add)), rec.moduleinst(eps, eps, eps, eps, eps, eps, eps, eps, eps)), syn.frame) .' \
  'red def.isize(f32) .' \
  'red def.fsize(i32) .' \
  'red def.jsize(f32) .' \
  'red def.jsizenn(f32) .' \
  'red def.subst-typevar(i32, eps, eps) .' \
  'red def.isize(i32) .' \
  'red def.fsize(f32) .' \
  'red def.jsize(i32) .' \
  'red def.jsizenn(i32) .' \
  'red def.subst-typevar(rec(0), eps, eps) .' \
  'search [1] rel.step(config.sym(state.sym(rec.store(eps, eps, eps, eps, eps, eps, eps, eps, eps, eps), rec.frame(eps, rec.moduleinst(eps, eps, eps, eps, eps, eps, eps, eps, eps))), const(i32, uN.wrap(7)) const(i32, uN.wrap(1)) const(i32, uN.wrap(2)) instr.binop(i32, binop.add))) =>1 config.sym(state.sym(rec.store(eps, eps, eps, eps, eps, eps, eps, eps, eps, eps), rec.frame(eps, rec.moduleinst(eps, eps, eps, eps, eps, eps, eps, eps, eps))), const(i32, uN.wrap(7)) const(i32, uN.wrap(3))) .' \
  'quit' \
  | maude -no-banner "$output" >"$maude_log" 2>&1

if grep -Eq 'Warning:|Advisory:|Error:' "$maude_log"; then
  cat "$maude_log" >&2
  exit 1
fi
test "$(grep -c 'result Bool: true' "$maude_log")" -eq 2
test "$(grep -c 'result Bool: false' "$maude_log")" -eq 2
for irreduced in \
  'result Nat: def.isize(f32)' \
  'result Nat: def.fsize(i32)' \
  'result Nat: def.jsize(f32)' \
  'result Nat: def.jsizenn(f32)' \
  'def.subst-typevar(i32, eps, eps)'
do
  grep -Fq "$irreduced" "$maude_log"
done
test "$(grep -c 'result NzNat: 32' "$maude_log")" -eq 4
grep -Fq 'result SpectecTerminal: rec(0)' "$maude_log"
test "$(grep -c 'Solution 1' "$maude_log")" -eq 1
