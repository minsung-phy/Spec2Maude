#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
tmp=${TMPDIR:-/tmp}
harness="$tmp/spec2maude-chat-modelcheck.maude"
module_term="$tmp/spec2maude-chat-module.term"
wasm="$tmp/spec2maude-chat-server.wasm"
log="$tmp/spec2maude-chat-modelcheck.log"
cd "$root"

wat2wasm "$root/benchmarks/chat/server.wat" -o "$wasm"

dune exec ./bin/wasm2maude.exe -- module \
  "$wasm" --term-only -o "$module_term"

awk -v module_term="$module_term" -v semantics="$root/builtins.maude" '
  /@SEMANTICS@/ { gsub("@SEMANTICS@", semantics) }
  $0 == "@INPUT_MODULE@" {
    while ((getline line < module_term) > 0) print line
    close(module_term)
    next
  }
  { print }
' "$root/benchmarks/chat/modelcheck.maude.in" >"$harness"

maude -no-banner "$harness" 2>&1 | tee "$log"

grep -q 'Solution 1' "$log"
test "$(grep -c 'No solution.' "$log")" -eq 1
grep -q 'result ModelCheckResult: counterexample' "$log"
test "$(grep -c 'result Bool: true' "$log")" -eq 3

if grep -Eq '^(Warning|Advisory|Error):' "$log"; then
  echo "Maude reported a warning, advisory, or error" >&2
  exit 1
fi

echo "Compiled-WAT chat reachability and LTL checks passed."
