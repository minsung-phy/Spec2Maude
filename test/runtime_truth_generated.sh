set -eu

exe=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
root=$(CDPATH= cd -- "$2" && pwd)
prefix=/tmp/spec2maude-runtime-truth-test
output="$prefix.maude"
builtins="$prefix-builtins.maude"
report="$prefix-builtins.md"
log="$prefix.log"
smoke_log="$prefix-smoke.log"
smoke_fixture="$root/test/runtime_truth_ref_ok_smoke.maude"

rm -f "$output" "$builtins" "$report" "$log" "$smoke_log"
cd "$root"
if ! "$exe" translate \
    -o "$output" --builtins "$builtins" --builtin-report "$report" \
    >"$log" 2>&1
then
  cat "$log" >&2
  echo 'source-complete target-chain translation failed' >&2
  exit 1
fi

grep -Eq '\[spec2maude\] diagnostics: total=[0-9]+ fatal=0 unsupported=0 skipped=[0-9]+ obligations=0 prelude_gaps=0' "$log"
grep -q 'target-chain-refute' "$output"
grep -q 'seed-ref-ok-rule-8' "$output"
grep -q 'truth-seed-miss-ref-ok' "$output"
grep -q 'seed-refute-8-source-boolean' "$output"
grep -q 'rule-refute-14-eq-pattern' "$output"
grep -Eq '_=/=_\(RTPAThelper[^,]*, TYPEUSE_STAR:SpectecTerminals\)' "$output"
if grep -Fq "_=/=_(index(value('TYPES'" "$output"; then
  echo 'type-index binding was emitted as a comparison against an unbound witness' >&2
  exit 1
fi

test -f "$output"
test -f "$builtins"
test -f "$report"

if ! (cd /tmp && maude -no-banner "$(basename "$builtins")" \
      "$smoke_fixture") >"$smoke_log" 2>&1
then
  cat "$smoke_log" >&2
  exit 1
fi
if grep -E 'Warning:|Advisory:|Error:' "$smoke_log" >/dev/null; then
  cat "$smoke_log" >&2
  exit 1
fi

assert_solution() {
  marker=$1
  section=$(awk -v begin="result Qid: '$marker-begin" \
    -v end="result Qid: '$marker-end" '
      $0 == begin { active = 1; next }
      $0 == end { active = 0; next }
      active { print }
    ' "$smoke_log")
  if [ "$(printf '%s\n' "$section" | grep -c '^Solution 1 ' || true)" -ne 1 ]; then
    cat "$smoke_log" >&2
    echo "$marker Ref_ok smoke search did not have exactly one solution" >&2
    exit 1
  fi
}

assert_solution ref-ok-positive
assert_solution ref-ok-negative
assert_solution ref-ok-no-seed
