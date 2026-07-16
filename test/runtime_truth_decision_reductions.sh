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

grep -q 'result RuntimeTruthWorklistPositiveConf: helper.truth-proved.positive' "$log"
grep -q 'result RuntimeTruthWorklistNegativeConf: helper.truth-refuted.negative' "$log"
grep -q 'result RuntimeTruthWorklistCyclicConf: helper.truth-refuted.cyclic' "$log"
grep -q 'result RuntimeTruthWorklistGuardProvedConf: helper.truth-proved.guardproved' "$log"
grep -q 'result RuntimeTruthWorklistGuardRefutedConf: helper.truth-refuted.guardrefuted' "$log"
grep -q '^result RuntimeTruthWorklistGuardMismatchConf:$' "$log"
grep -q '^    helper.truth-refuted.guardmismatch$' "$log"

grep -q '\[guardrefuted-rule-head-guard-' "$output"
grep -q '\[guardmismatch-rule-mismatch-' "$output"
