#!/bin/sh
set -eu

fixture=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
output=/tmp/spec2maude-iter-rule-fixture.maude
log=/tmp/spec2maude-iter-rule-fixture.log

"$fixture" >"$output"
printf '%s\n' quit | maude -no-banner "$output" >"$log" 2>&1

if grep -Eq '(^|[^A-Za-z])(Warning|Error):' "$log"; then
  cat "$log" >&2
  exit 1
fi

grep -Fq 'op fixtureAll : SpectecTerminals -> IterPremiseRuleFixtureAllConf [frozen (1)]' "$output"
grep -Fq 'op fixtureExists : SpectecTerminals -> IterPremiseRuleFixtureExistsConf [frozen (1)]' "$output"
grep -Fq 'op fixtureZip : SpectecTerminals SpectecTerminals Nat -> IterPremiseRuleFixtureZipConf [frozen (1 2 3)]' "$output"
grep -Fq 'op fixtureProofResult : Nat -> FixtureProof [ctor]' "$output"
grep -Fq 'fixtureProof(ZH1) => fixtureProofResult(ZW) /\ (_==_(ZW, ZH2)) = true /\ fixtureZip(ZT1, ZT2, ZC) => helper.premise-zip-ok.fixturezip' "$output"
grep -Fq 'result IterPremiseRuleFixtureAllConf: helper.premise-all-ok.fixtureall' "$log"
grep -Fq 'result IterPremiseRuleFixtureExistsConf: helper.premise-exists-ok.fixtureexists' "$log"
grep -Fq 'result IterPremiseRuleFixtureZipConf: helper.premise-zip-ok.fixturezip' "$log"
