#!/bin/sh
set -eu

fixture=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
output=/tmp/spec2maude-membership-witness.maude
log=/tmp/spec2maude-membership-witness.log

"$fixture" >"$output"
printf '%s\n' quit | maude -no-banner "$output" >"$log" 2>&1

if grep -Eq '(^|[^A-Za-z])(Advisory|Warning|Error):' "$log"; then
  cat "$log" >&2
  exit 1
fi

for member in 0 1 2; do
  grep -q "^X --> $member$" "$log"
done
grep -q '^X --> 7$' "$log"

test "$(grep -c '^No solution\.$' "$log")" -eq 3
