#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
tmp=${TMPDIR:-/tmp}
output="$tmp/spec2maude-builtins-output.maude"
builtins="$tmp/spec2maude-builtins.maude"
report="$tmp/spec2maude-builtins.md"
translate_log="$tmp/spec2maude-builtins-translate.log"
output_log="$tmp/spec2maude-builtins-output-load.log"
builtin_log="$tmp/spec2maude-builtins-load.log"
smoke="$tmp/spec2maude-builtins-smoke.maude"
smoke_log="$tmp/spec2maude-builtins-smoke.log"
cd "$root"

dune exec ./bin/spec2maude.exe -- translate \
    -o "$output" --builtins "$builtins" --builtin-report "$report" \
    >"$translate_log" 2>&1

grep -q '\[spec2maude\] diagnostics:.*fatal=0 unsupported=0.*obligations=12 prelude_gaps=0' "$translate_log"
grep -q 'inverse metadata is unavailable: inverse target `inv_ibits_` does not structurally swap' "$translate_log"
grep -q -- '- implemented: 68' "$report"
grep -q -- '- active obligations: 12' "$report"

load_clean() {
  file=$1
  log=$2
  printf '%s\n' quit | maude -no-banner "$file" >"$log" 2>&1
  if grep -Eq '^(Warning|Advisory|Error):' "$log"; then
    grep -E '^(Warning|Advisory|Error):' "$log" >&2
    exit 1
  fi
}

load_clean "$output" "$output_log"
load_clean "$builtins" "$builtin_log"

{
  printf 'load %s\n' "$builtins"
  awk -F'|' '$6 ~ /IMPLEMENTED/ {
    smoke = $8
    sub(/^[[:space:]]*/, "", smoke)
    sub(/[[:space:]]*$/, "", smoke)
    print smoke
  }' "$report"
} >"$smoke"

test "$(grep -c '^red in WASM-BUILTINS' "$smoke")" -eq 68
{ cat "$smoke"; printf '%s\n' quit; } | maude -no-banner >"$smoke_log" 2>&1
test "$(grep -c '^result ' "$smoke_log")" -eq 68

if grep -Eq '^(Warning|Advisory|Error):' "$smoke_log"; then
  grep -E '^(Warning|Advisory|Error):' "$smoke_log" >&2
  exit 1
fi

if awk '
  /^result / { in_result = 1 }
  /^=+$/ { in_result = 0 }
  in_result && /(^|[ (])(def[^ (]*|builtin\.)/ { exit 1 }
' "$smoke_log"; then
  :
else
  echo "implemented builtin smoke left a residual defined/helper term" >&2
  exit 1
fi

echo "Builtin load and all 68 implemented smoke checks passed."
