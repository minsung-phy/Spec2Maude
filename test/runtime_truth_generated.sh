set -eu

exe=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
root=$(CDPATH= cd -- "$2" && pwd)
prefix=/tmp/spec2maude-runtime-truth-test
output="$prefix.maude"
builtins="$prefix-builtins.maude"
report="$prefix-builtins.md"
log="$prefix.log"

rm -f "$output" "$builtins" "$report" "$log"
cd "$root"
if "$exe" translate \
    -o "$output" --builtins "$builtins" --builtin-report "$report" \
    >"$log" 2>&1
then
  echo 'target-chain Decide unexpectedly produced a complete translation' >&2
  exit 1
fi

grep -Eq '\[spec2maude\] diagnostics: total=[0-9]+ fatal=[1-9][0-9]* unsupported=[1-9][0-9]* skipped=[0-9]+ obligations=0 prelude_gaps=0' "$log"
test "$(grep -c 'constructor: RuntimeTruthWorklist/target-chain/decision-unsupported' "$log")" -eq 1
grep -q 'source target-chain RuleD `Ref_ok/sub`' "$log"
grep -q 'one failing seed witness cannot establish false' "$log"

test ! -e "$output"
test ! -e "$builtins"
test -f "$report"
