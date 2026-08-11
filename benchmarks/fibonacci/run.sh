#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
tmp=${TMPDIR:-/tmp}
modelcheck="$tmp/spec2maude-fibonacci-modelcheck.maude"
wasm="$tmp/spec2maude-fibonacci.wasm"
maude_log="$tmp/spec2maude-fibonacci-modelcheck.log"
cd "$root"

wat2wasm benchmarks/fibonacci/fib.wat -o "$wasm"

dune exec ./bin/wasm2maude.exe -- modelcheck \
  "$wasm" \
  --invoke fib \
  --arg i32:5 --arg i32:0 --arg i32:1 \
  --expect i32:5 --reject i32:6 \
  --semantics "$root/builtins.maude" \
  -o "$modelcheck"

maude -no-banner "$modelcheck" 2>&1 \
  | tee "$maude_log"

grep -q 'Solution 1' "$maude_log"
test "$(grep -c 'No solution.' "$maude_log")" -eq 1
test "$(grep -c 'result Bool: true' "$maude_log")" -eq 2
grep -q 'result ModelCheckResult: counterexample' "$maude_log"

if grep -Eq '^(Warning|Advisory|Error):' "$maude_log"; then
  echo "Maude reported a warning, advisory, or error" >&2
  exit 1
fi

echo "Compiled-WAT Fibonacci rewrite, search, and LTL checks passed."
