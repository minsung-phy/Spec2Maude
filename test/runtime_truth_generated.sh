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
if ! "$exe" translate \
    -o "$output" --builtins "$builtins" --builtin-report "$report" \
    >"$log" 2>&1
then
  cat "$log" >&2
  echo 'runtime truth translation failed' >&2
  exit 1
fi

grep -q '\[spec2maude\] diagnostics: total=1289 fatal=0 unsupported=0 skipped=1289 obligations=0 prelude_gaps=0' "$log"
if grep -Eq '^fatal:|PARTIAL/INCOMPLETE' "$log"; then
  echo 'runtime truth translation retained fatal or partial-output diagnostics' >&2
  exit 1
fi
if grep -q 'Deftype_sub/super \[RuntimeTruthSuccessorDomain/delegated/call-not-source-complete-deterministic\]' "$log"; then
  echo 'single-clause zero-or-one successor binding regressed' >&2
  exit 1
fi
if grep -q 'Heaptype_sub/trans \[RuntimeTruthScc/RulePr/open-successor\]' "$log"; then
  echo 'finite direct-successor worklist regressed' >&2
  exit 1
fi
if grep -q 'RelD/ElsePr/enabledness/group-complement' "$log"; then
  echo 'throw_ref constructor-group complement remained fatal' >&2
  exit 1
fi

test -f "$output"
test -f "$builtins"
test -f "$report"
sh "$root/test/constructor_component_generated.sh" "$output"
sh "$root/test/record_semantics_generated.sh" "$output"
if grep -Eq '^--- PARTIAL/INCOMPLETE VERIFICATION' "$output" "$builtins"; then
  echo 'successful runtime truth translation was marked partial' >&2
  exit 1
fi
grep -q '^  op def.instantiate ' "$output"
grep -q '^  op def.invoke ' "$output"
grep -q 'helper-enabledness-step-read-enabled-false' "$output"
grep -q 'helper-enabledness-step-read-4-enabled-false' "$output"
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
  if grep -Eq 'Warning:|Advisory:|Error:' "$load_log"; then
    cat "$load_log" >&2
    echo 'generated Maude load emitted a warning or error' >&2
    exit 1
  fi
done

if ! "$exe" translate -o "$explicit_output" "$root"/wasm-3.0/*.spectec \
    >"$explicit_log" 2>&1
then
  cat "$explicit_log" >&2
  echo 'explicit-input translation failed' >&2
  exit 1
fi
grep -q '\[spec2maude\] diagnostics: total=1289 fatal=0 unsupported=0 skipped=1289 obligations=0 prelude_gaps=0' "$explicit_log"
grep -q 'from contract config/wasm-3.0-runtime-ingress.contract:2' "$explicit_log"
grep -q 'from contract config/wasm-3.0-runtime-ingress.contract:3' "$explicit_log"
test -f "$explicit_output"
