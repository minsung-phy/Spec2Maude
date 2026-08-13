#!/bin/sh
set -eu

fixture=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
output=/tmp/spec2maude-nested-typecheck-fixture.maude
log=/tmp/spec2maude-nested-typecheck-fixture.log

"$fixture" >"$output"

if grep -Eq 'typecheck(OptSeq|SeqOpt|NestedSeq)' "$output"; then
  echo "obsolete specialized typecheck operator was emitted" >&2
  exit 1
fi

printf '%s\n' quit | maude -no-banner "$output" >"$log" 2>&1

if grep -Eq 'Warning:|Advisory:|Error:' "$log"; then
  cat "$log" >&2
  exit 1
fi

test "$(grep -c '^result Bool: true$' "$log")" -eq 4
test "$(grep -c '^result Bool: false$' "$log")" -eq 3
grep -Eq '^result SpectecTerminals: bool\(true\) bool\(false\)$' "$log"
