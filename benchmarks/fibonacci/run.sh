#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
tmp=${TMPDIR:-/tmp}
maude_log="$tmp/spec2maude-fibonacci-modelcheck.log"
cd "$root"

maude -no-banner builtins.maude benchmarks/fibonacci/modelcheck.maude 2>&1 \
  | tee "$maude_log"

grep -q 'Solution 1' "$maude_log"
test "$(grep -c 'No solution.' "$maude_log")" -eq 1
test "$(grep -c 'result Bool: true' "$maude_log")" -eq 2
grep -q 'result ModelCheckResult: counterexample' "$maude_log"

if grep -Eq '^(Warning|Advisory|Error):' "$maude_log"; then
  echo "Maude reported a warning, advisory, or error" >&2
  exit 1
fi

echo "Fibonacci rewrite, search, and LTL checks passed."
