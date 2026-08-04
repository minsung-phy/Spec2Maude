#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
out_dir=${1:-"${TMPDIR:-/tmp}/spec2maude-instantiation-reentrancy"}
mkdir -p "$out_dir"
cd "$root"

maude_bin=${MAUDE:-maude}

for name in provider victim zombie-provider zombie-victim; do
  dune exec --profile release ./bin/wasm2maude.exe -- module \
    "benchmarks/instantiation-reentrancy/${name}.wat" \
    --semantics builtins.maude \
    -o "$out_dir/${name}-typecheck.maude"
  "$maude_bin" -no-banner "$out_dir/${name}-typecheck.maude" \
    > "$out_dir/${name}-typecheck.log" 2>&1
  grep -q 'result Bool: true' "$out_dir/${name}-typecheck.log"
done

dune exec --profile release ./bin/wasm2maude.exe -- wast-run \
  benchmarks/instantiation-reentrancy/reentrant-start.wast \
  --semantics builtins.maude \
  --steps 4000000 \
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

# Reuse the generated WAST transition system as a Kripke structure.
# 1. A victim function observes partial initialization while its start runs.
# 2. A function belonging to a failed instance remains executable through a
#    table entry whose mutation was not rolled back.
"$maude_bin" -no-banner \
  "$out_dir/reentrant-start.maude" \
  benchmarks/instantiation-reentrancy/modelcheck.maude \
  > "$out_dir/modelcheck.log" 2>&1

test "$(grep -c '^Solution 1' "$out_dir/modelcheck.log")" -eq 2
test "$(grep -c 'result ModelCheckResult: counterexample' "$out_dir/modelcheck.log")" -eq 2

wat2wasm benchmarks/instantiation-reentrancy/provider.wat \
  -o "$out_dir/provider.wasm"
wat2wasm benchmarks/instantiation-reentrancy/victim.wat \
  -o "$out_dir/victim.wasm"
node benchmarks/instantiation-reentrancy/node-repro.mjs \
  "$out_dir/provider.wasm" "$out_dir/victim.wasm" \
  > "$out_dir/node-reentrancy.log"

grep -q '^during_start=0$' "$out_dir/node-reentrancy.log"
grep -q '^after_start=1$' "$out_dir/node-reentrancy.log"

wat2wasm benchmarks/instantiation-reentrancy/zombie-provider.wat \
  -o "$out_dir/zombie-provider.wasm"
wat2wasm benchmarks/instantiation-reentrancy/zombie-victim.wat \
  -o "$out_dir/zombie-victim.wasm"
node benchmarks/instantiation-reentrancy/node-zombie.mjs \
  "$out_dir/zombie-provider.wasm" "$out_dir/zombie-victim.wasm" \
  > "$out_dir/node-zombie.log"

grep -q '^instantiation_trapped=true$' "$out_dir/node-zombie.log"
grep -q '^zombie_result=42$' "$out_dir/node-zombie.log"

if grep -Eq '^(Warning|Advisory|Error):' "$out_dir"/*.log; then
  grep -En '^(Warning|Advisory|Error):' "$out_dir"/*.log >&2 || true
  exit 1
fi

{
  echo 'Spec2Maude WebAssembly instantiation-lifecycle result'
  echo '====================================================='
  echo "commit=$(git rev-parse HEAD)"
  echo "maude=$($maude_bin --version 2>&1 | head -n 1 || true)"
  echo "node=$(node --version)"
  echo
  echo 'provider/victim module typechecks: PASS'
  echo 'zombie-provider/zombie-victim module typechecks: PASS'
  echo 'Spec2Maude linked WAST execution: PASS'
  echo
  echo '[Finding 1] construction reentrancy'
  echo 'reachability: partial observation DURING instantiation is reachable'
  echo 'LTL [] ~ partial-observation: counterexample'
  echo 'during victim start, table-reentrant call observed ready=0'
  echo 'after victim start, the same table function observed ready=1'
  echo 'Node/V8 confirmation: PASS'
  echo
  echo '[Finding 2] failed-instantiation zombie capability'
  echo 'reachability: failed-module code execution is reachable'
  echo 'LTL [] ~ zombie-execution: counterexample'
  echo 'victim start trapped, but provider.table still invoked victim code -> 42'
  echo 'failed victim instance is absent from the instance environment'
  echo 'Node/V8 confirmation: PASS'
  echo
  echo 'WAST/Maude statistics:'
  grep -E '^(rewrites:|states:|result (ScriptState|ModelCheckResult):)' \
    "$out_dir/reentrant-start.log" "$out_dir/modelcheck.log" || true
} | tee "$out_dir/results.txt"

echo "Artifacts written to $out_dir"
