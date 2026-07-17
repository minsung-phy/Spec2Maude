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
smoke_fixture="$root/test/builtin_backend_smoke.maude"
smoke_log="$tmp/spec2maude-builtins-smoke.log"
cd "$root"

dune exec ./bin/spec2maude.exe -- translate \
    -o "$output" --builtins "$builtins" --builtin-report "$report" \
    >"$translate_log" 2>&1

grep -q '\[spec2maude\] diagnostics:.*fatal=0 unsupported=0.*obligations=0 prelude_gaps=0' "$translate_log"
grep -q 'inverse metadata is unavailable: inverse target `inv_ibits_` does not structurally swap' "$translate_log"
grep -q -- '- implemented: 87' "$report"
grep -q -- '- active obligations: 0' "$report"

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

smoke_count=$(grep -c '^red in WASM-BUILTINS' "$smoke_fixture")
maude -no-banner "$builtins" "$smoke_fixture" >"$smoke_log" 2>&1
test "$(grep -c '^result ' "$smoke_log")" -eq "$smoke_count"

if grep -Eq '^(Warning|Advisory|Error):' "$smoke_log"; then
  grep -E '^(Warning|Advisory|Error):' "$smoke_log" >&2
  exit 1
fi

if awk '
  /^result / { in_result = 1 }
  /^=+$/ { in_result = 0 }
  in_result && /builtin\.inv-concat\(syn\.nat, 1 2 3\)$/ {
    inv_concat++
    next
  }
  in_result && /builtin\.inv-concatn\(syn\.nat, 2, 1 2 3\)$/ {
    inv_concatn++
    next
  }
  in_result && /builtin\.inv-concatn\(syn\.nat, 0, 1 2\)$/ {
    inv_concatn_zero++
    next
  }
  in_result && /(^|[ (])(def[^ (]*|builtin\.)/ { exit 1 }
  END { exit !(inv_concat == 1 && inv_concatn == 1 && inv_concatn_zero == 1) }
' "$smoke_log"; then
  :
else
  echo "builtin smoke left an unexpected residual defined/helper term" >&2
  exit 1
fi

echo "Builtin load and all $smoke_count smoke checks passed; active obligations: 0."
