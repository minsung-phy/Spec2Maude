set -eu

exe=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
root=$(CDPATH= cd -- "$2" && pwd)
prefix=/tmp/spec2maude-runtime-truth-test
output="$prefix.maude"
builtins="$prefix-builtins.maude"
report="$prefix-builtins.md"
log="$prefix.log"
maude_log="$prefix-maude.log"
builtins_maude_log="$prefix-builtins-maude.log"
explicit_output="$prefix-explicit.maude"
explicit_log="$prefix-explicit.log"

rm -f "$output" "$builtins" "$report" "$log" "$maude_log" \
  "$builtins_maude_log" "$explicit_output" "$explicit_log"
cd "$root"
if "$exe" translate --emit-partial \
    -o "$output" --builtins "$builtins" --builtin-report "$report" \
    >"$log" 2>&1
then
  echo 'unsafe runtime truth translation unexpectedly became nonfatal' >&2
  exit 1
fi

grep -q '\[spec2maude\] diagnostics: total=1301 fatal=12 unsupported=12 skipped=1289 obligations=0 prelude_gaps=0' "$log"
grep -q 'WARNING: fatal diagnostics remain; writing marked partial/incomplete verification output' "$log"
grep -q 'Deftype_sub/super \[RuntimeTruthSuccessorDomain/delegated/call-not-source-complete-deterministic\]' "$log"
grep -q 'Heaptype_sub/trans \[RuntimeTruthScc/RulePr/open-successor\]' "$log"
grep -q 'no finite ground enumerator has been established' "$log"
if grep -q 'RelD/ElsePr/enabledness/group-complement' "$log"; then
  echo 'throw_ref constructor-group complement remained fatal' >&2
  exit 1
fi

test -f "$output"
test -f "$builtins"
test -f "$report"
grep -q '^--- PARTIAL/INCOMPLETE VERIFICATION OUTPUT:' "$output"
grep -q '^--- PARTIAL/INCOMPLETE VERIFICATION BUILTINS:' "$builtins"
grep -q '^  op def.instantiate ' "$output"
grep -q '^  op def.invoke ' "$output"
if grep -Eq '^[[:space:]]*(rl|crl).*\[owise\]' "$output"; then
  echo 'partial output contains execution [owise]' >&2
  exit 1
fi
grep -q -- '- implemented: 87' "$report"
grep -q -- '- active obligations: 0' "$report"

printf '%s\n' quit | maude -no-banner "$output" >"$maude_log" 2>&1
printf '%s\n' quit | maude -no-banner "$builtins" >"$builtins_maude_log" 2>&1
for load_log in "$maude_log" "$builtins_maude_log"; do
  if grep -q 'multiple distinct parses' "$load_log"; then
    echo 'generated constructor surface remains parse-ambiguous' >&2
    exit 1
  fi
  if grep -E "didn't expect token|bad token" "$load_log" \
      | grep -v 'step-read' >/dev/null; then
    echo 'Maude load contains a stale bad-token warning' >&2
    exit 1
  fi
  if grep -Eq 'Warning:|Advisory:|Error:' "$load_log"; then
    grep -Eq "(didn't expect token|bad token) rel[.]step-read" "$load_log"
    grep -q 'no parse for statement' "$load_log"
  fi
done

if "$exe" translate -o "$explicit_output" "$root"/wasm-3.0/*.spectec \
    >"$explicit_log" 2>&1
then
  echo 'unsafe explicit-input translation unexpectedly became nonfatal' >&2
  exit 1
fi
grep -q '\[spec2maude\] diagnostics: total=1301 fatal=12 unsupported=12 skipped=1289 obligations=0 prelude_gaps=0' "$explicit_log"
grep -q 'from contract config/wasm-3.0-runtime-ingress.contract:2' "$explicit_log"
grep -q 'from contract config/wasm-3.0-runtime-ingress.contract:3' "$explicit_log"
test ! -e "$explicit_output"
