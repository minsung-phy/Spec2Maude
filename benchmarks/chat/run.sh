#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
out_dir=${1:-"${TMPDIR:-/tmp}/spec2maude-chat"}
mkdir -p "$out_dir"
cd "$root"

maude_bin=${MAUDE:-maude}

# 1. Exercise the actual wasm2maude frontend on the Wasm chat-client module.
dune exec --profile release ./bin/wasm2maude.exe -- module \
  benchmarks/chat/chat-client.wat \
  --semantics builtins.maude \
  -o "$out_dir/chat-client-typecheck.maude"
"$maude_bin" -no-banner "$out_dir/chat-client-typecheck.maude" \
  > "$out_dir/chat-client-typecheck.log" 2>&1

grep -q 'result Bool: true' "$out_dir/chat-client-typecheck.log"

# 2. End-to-end concrete executions of the same guard.
dune exec --profile release ./bin/wasm2maude.exe -- run \
  benchmarks/chat/chat-client.wat \
  --invoke accept --arg i32:0 --arg i32:0 --steps 10000 \
  --semantics builtins.maude \
  -o "$out_dir/chat-accept-00.maude"
"$maude_bin" -no-banner "$out_dir/chat-accept-00.maude" \
  > "$out_dir/chat-accept-00.log" 2>&1

dune exec --profile release ./bin/wasm2maude.exe -- run \
  benchmarks/chat/chat-client.wat \
  --invoke accept --arg i32:0 --arg i32:1 --steps 10000 \
  --semantics builtins.maude \
  -o "$out_dir/chat-accept-01.maude"
"$maude_bin" -no-banner "$out_dir/chat-accept-01.maude" \
  > "$out_dir/chat-accept-01.log" 2>&1

grep -q 'instr.const(numtype.i32, uN.wrap(1))' "$out_dir/chat-accept-00.log"
grep -q 'instr.const(numtype.i32, uN.wrap(0))' "$out_dir/chat-accept-01.log"

# 3. Explore all message-delivery interleavings in the distributed wrapper.
"$maude_bin" -no-banner builtins.maude benchmarks/chat/modelcheck.maude \
  > "$out_dir/modelcheck.log" 2>&1

# Expected command sequence:
#   search complete state       -> Solution 1
#   search bad correct state    -> No solution
#   search bad mutant state     -> Solution 1
#   LTL correct invariant       -> true
#   LTL mutant invariant        -> counterexample
test "$(grep -c '^Solution 1' "$out_dir/modelcheck.log")" -ge 2
test "$(grep -c '^No solution\.' "$out_dir/modelcheck.log")" -eq 1
grep -q 'result Bool: true' "$out_dir/modelcheck.log"
grep -q 'result ModelCheckResult: counterexample' "$out_dir/modelcheck.log"

if grep -Eq '^(Warning|Advisory|Error):' \
    "$out_dir/chat-client-typecheck.log" \
    "$out_dir/chat-accept-00.log" \
    "$out_dir/chat-accept-01.log" \
    "$out_dir/modelcheck.log"; then
  echo 'Maude reported a warning, advisory, or error.' >&2
  grep -En '^(Warning|Advisory|Error):' "$out_dir"/*.log >&2 || true
  exit 1
fi

{
  echo 'Spec2Maude distributed chat model-checking result'
  echo '================================================'
  echo "commit=$(git rev-parse HEAD)"
  echo "maude=$($maude_bin --version 2>&1 | head -n 1 || true)"
  echo
  echo 'wasm2maude module typecheck: PASS'
  echo 'accept(expected=0,incoming=0): 1 (PASS)'
  echo 'accept(expected=0,incoming=1): 0 (PASS)'
  echo 'reachable complete correct state: YES'
  echo 'correct protocol bad-order state: NOT REACHABLE'
  echo 'buggy >= mutant bad-order state: REACHABLE'
  echo 'correct LTL [] ~ bad-order: true'
  echo 'buggy LTL [] ~ bad-order: counterexample'
  echo
  echo 'Maude statistics:'
  grep -E '^(rewrites:|states:|result (Bool|ModelCheckResult):)' "$out_dir/modelcheck.log" || true
} | tee "$out_dir/results.txt"

echo "Artifacts written to $out_dir"
