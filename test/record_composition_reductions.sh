#!/bin/sh
set -eu

fixture=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
output=/tmp/spec2maude-record-composition-fixture.maude
log=/tmp/spec2maude-record-composition-fixture.log

"$fixture" >"$output"
printf '%s\n' quit | maude -no-banner "$output" >"$log" 2>&1

if grep -Eq 'Warning:|Advisory:|Error:' "$log"; then
  cat "$log" >&2
  exit 1
fi

grep -Fq 'op compose.rec.record-probe : SpectecTerminal SpectecTerminal ~> SpectecTerminal .' "$output"
grep -Fq 'composeOpt(LEFT_MAYBE' "$output"
grep -Fq 'LEFT_VALUES:SpectecTerminals RIGHT_VALUES' "$output"
grep -Fq 'compose.rec.nested-probe(LEFT_NESTED' "$output"
grep -Fq 'result SpectecTerminal: rec.record-probe(0, 1 2, rec.nested-probe(3 4))' "$log"
grep -Eq '^result \[[^]]*SpectecTerminal[^]]*\]: rec\.record-probe\(composeOpt\(0, 5\),' "$log"
