#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
out_dir=${1:-"${TMPDIR:-/tmp}/spec2maude-instantiation-reentrancy"}
mkdir -p "$out_dir"
cd "$root"

maude_bin=${MAUDE:-maude}

# Encode/typecheck both real Wasm modules through wasm2maude.
for name in provider victim; do
  dune exec --profile release ./bin/wasm2maude.exe -- module \
    "benchmarks/instantiation-reentrancy/${name}.wat" \
    --semantics builtins.maude \
    -o "$out_dir/${name}-typecheck.maude"
  "$maude_bin" -no-banner "$out_dir/${name}-typecheck.maude" \
    > "$out_dir/${name}-typecheck.log" 2>&1
  grep -q 'result Bool: true' "$out_dir/${name}-typecheck.log"
done

# Execute the linked multi-module WAST script entirely through Spec2Maude's
# generated WebAssembly semantics.
dune exec --profile release ./bin/wasm2maude.exe -- wast-run \
  benchmarks/instantiation-reentrancy/reentrant-start.wast \
  --semantics builtins.maude \
  --steps 2000000 \
  --call-depth 256 \
  -o "$out_dir/reentrant-start.maude" \
  2> "$out_dir/wast-emit.log"

"$maude_bin" -no-banner "$out_dir/reentrant-start.maude" \
  > "$out_dir/reentrant-start.log" 2>&1

grep -q 'result ScriptState: script.done' "$out_dir/reentrant-start.log"
if grep -Eq 'script\.(wrong-result|wrong-assertion|link-error)' "$out_dir/reentrant-start.log"; then
  cat "$out_dir/reentrant-start.log" >&2
  exit 1
fi

# Confirm the same semantic witness in a production engine (Node/V8).
wat2wasm benchmarks/instantiation-reentrancy/provider.wat \
  -o "$out_dir/provider.wasm"
wat2wasm benchmarks/instantiation-reentrancy/victim.wat \
  -o "$out_dir/victim.wasm"
node benchmarks/instantiation-reentrancy/node-repro.mjs \
  "$out_dir/provider.wasm" "$out_dir/victim.wasm" \
  > "$out_dir/node.log"

grep -q '^during_start=0$' "$out_dir/node.log"
grep -q '^after_start=1$' "$out_dir/node.log"

if grep -Eq '^(Warning|Advisory|Error):' "$out_dir"/*.log; then
  grep -En '^(Warning|Advisory|Error):' "$out_dir"/*.log >&2 || true
  exit 1
fi

{
  echo 'Spec2Maude WebAssembly instantiation-reentrancy result'
  echo '======================================================='
  echo "commit=$(git rev-parse HEAD)"
  echo "maude=$($maude_bin --version 2>&1 | head -n 1 || true)"
  echo "node=$(node --version)"
  echo
  echo 'provider.wat typecheck: PASS'
  echo 'victim.wat typecheck: PASS'
  echo 'Spec2Maude linked WAST execution: PASS'
  echo 'during victim start, table-reentrant call observed ready=0'
  echo 'after victim start, the same table function observed ready=1'
  echo 'Node/V8 confirmation: PASS'
  echo
  echo 'WAST/Maude statistics:'
  grep -E '^(rewrites:|result ScriptState:)' "$out_dir/reentrant-start.log" || true
} | tee "$out_dir/results.txt"

echo "Artifacts written to $out_dir"
