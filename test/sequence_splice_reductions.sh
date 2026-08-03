#!/bin/sh
set -eu

fixture=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
output=/tmp/spec2maude-sequence-splice-fixture.maude
log=/tmp/spec2maude-sequence-splice-fixture.log

"$fixture" >"$output"
printf '%s\n' quit | maude -no-banner "$output" >"$log" 2>&1

if grep -Eq 'Warning:|Advisory:|Error:' "$log"; then
  cat "$log" >&2
  exit 1
fi

if grep '^result Bool:' "$log" | grep -v '^result Bool: true$'; then
  cat "$log" >&2
  exit 1
fi

test "$(grep -c '^result Bool: true$' "$log")" -eq 361
