set -eu

fixture=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
output=/tmp/spec2maude-runtime-truth-decision-fixture.maude
log=/tmp/spec2maude-runtime-truth-decision-fixture.log

"$fixture" >"$output"
printf '%s\n' quit | maude -no-banner "$output" >"$log" 2>&1

if grep -Eq 'Warning:|Advisory:|Error:' "$log"; then
  cat "$log" >&2
  exit 1
fi

search_section() {
  section_marker=$1
  awk -v begin="result Qid: '$section_marker-begin" \
      -v end="result Qid: '$section_marker-end" '
    $0 == begin { begins++; active = 1; next }
    $0 == end { ends++; active = 0; next }
    active { print }
    END { if (begins != 1 || ends != 1) exit 2 }
  ' "$log"
}

assert_search() {
  search_name=$1
  search_marker=$2
  search_expected=$3
  if ! section=$(search_section "$search_marker"); then
    echo "$search_name search section markers were missing or ambiguous" >&2
    cat "$log" >&2
    exit 1
  fi
  solutions=$(printf '%s\n' "$section" | grep -c '^Solution ' || true)
  no_solution=$(printf '%s\n' "$section" | grep -c '^No solution\.$' || true)
  if [ "$search_expected" = reachable ]; then
    valid=$([ "$solutions" -eq 1 ] && [ "$no_solution" -eq 0 ] && echo yes || true)
  else
    valid=$([ "$solutions" -eq 0 ] && [ "$no_solution" -eq 1 ] && echo yes || true)
  fi
  if [ "$valid" != yes ]; then
    echo "$search_name $search_marker was not $search_expected" >&2
    printf '%s\n' "$section" >&2
    exit 1
  fi
}

assert_decide() {
  decide_name=$1
  decide_marker=$2
  decide_expected=$3
  decide_opposite=$4
  assert_search "$decide_name $decide_expected" \
    "search-$decide_marker-$decide_expected" reachable
  assert_search "$decide_name $decide_opposite" \
    "search-$decide_marker-$decide_opposite" unreachable
}

assert_decide Positive positive proved refuted
assert_decide Negative negative refuted proved
assert_decide Cyclic cyclic refuted proved
assert_decide GuardProved guardproved proved refuted
assert_decide GuardRefuted guardrefuted refuted proved
assert_decide GuardMismatch guardmismatch refuted proved
assert_decide BoolGuardTrue boolguardtrue proved refuted
assert_decide BoolGuardFalse boolguardfalse refuted proved

assert_search 'Registry failed Prove proved terminal' \
  search-registry-failed-proved unreachable
assert_search 'Registry failed Prove refuted terminal' \
  search-registry-failed-refuted unreachable

grep -q 'result RuntimeTruthWorklistTransitiveOrderConf:' "$log"
grep -q 'result RuntimeTruthWorklistTransitiveClosureConf:' "$log"
grep -q 'result RuntimeTruthWorklistHelperTruthWorklistRegistrychainproveConf:' "$log"

direct_rewrites=$(awk '
  /TransitiveOrder\(0, 1\)/ { found = 1; next }
  found && /^rewrites:/ { print $2; exit }
' "$log")
if [ -z "$direct_rewrites" ] || [ "$direct_rewrites" -gt 8 ]; then
  echo 'ordinary direct proof did not remain bounded and fast' >&2
  cat "$log" >&2
  exit 1
fi

grep -q '\[guardrefuted-rule-head-guard-' "$output"
grep -q '\[guardmismatch-rule-mismatch-' "$output"
