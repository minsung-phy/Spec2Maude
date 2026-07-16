#!/bin/sh
set -eu

fixture=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
output=/tmp/spec2maude-rewrite-decd-fixture.maude
log=/tmp/spec2maude-rewrite-decd-fixture.log

"$fixture" >"$output"
printf '%s\n' quit | maude -no-banner "$output" >"$log" 2>&1

if grep -Eq '(^|[^A-Za-z])(Warning|Error):' "$log"; then
  cat "$log" >&2
  exit 1
fi

grep -q 'result SpectecTerminal: tuple(2 seq(100 200))' "$log"
