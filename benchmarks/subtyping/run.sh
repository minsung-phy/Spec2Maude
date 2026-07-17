#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
tmp=${TMPDIR:-/tmp}
output="$tmp/spec2maude-subtyping.maude"
log="$tmp/spec2maude-subtyping.log"
minat="$tmp/spec2maude-subtyping-minat.maude"
cd "$root"

dune exec ./bin/spec2maude.exe -- translate \
  -o "$output" >"$log" 2>&1
grep -q '\[spec2maude\] diagnostics:.*fatal=0 unsupported=0' "$log"

awk '
  /1\.2-syntax\.types\.spectec:291\.1-/ { in_minat = 1 }
  /1\.2-syntax\.types\.spectec:295\.1-/ { in_minat = 0 }
  in_minat { print }
' "$output" >"$minat"

# The first minat clause compares both address operands through their certified
# representation change; each operand occurs in both the size call and guard.
test "$(grep -o 'helper\.subtype-inject\.unop(' "$minat" | wc -l | tr -d ' ')" -eq 4

# The two audited execution rules inject unpackfield's val result into instr.
test "$(grep -c '=> helper\.subtype-inject\.step-pure(def\.unpackfield' "$output")" -eq 2

# The exact addrtype surface is I32/I64. No target-only valtype case projects.
test "$(grep -c '^  eq helper\.subtype-inject\.unop(addrtype\.' "$output")" -eq 2
test "$(grep -c '^  eq helper\.subtype-project\.unop(numtype\.' "$output")" -eq 2
if grep -q '^  eq helper\.subtype-project\.unop(\(numtype\.f32\|numtype\.f64\|vectype\.\|ref\.\)' "$output"; then
  echo "target-only valtype value received an addrtype projection" >&2
  exit 1
fi

# Pattern injection binds a fresh target carrier before projecting the source.
grep -q 'VAL[^ ]*:SpectecTerminal := helper\.subtype-project\.step-pure(PATTERN[0-9]*:SpectecTerminal)' "$output"

# instr.drop is outside the certified val image. Retraction remains partial.
if grep -q 'helper\.subtype-project\.step-pure(instr\.drop' "$output"; then
  echo "target-only instr.drop received a val projection" >&2
  exit 1
fi
if grep 'helper\.subtype-project\(-seq\)\?\..*\[owise\]' "$output"; then
  echo "subtype projection contains an [owise] fallback" >&2
  exit 1
fi

echo "Certified SubE generated-output checks passed."
