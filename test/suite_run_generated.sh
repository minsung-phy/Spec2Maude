#!/bin/sh
set -eu

wasm2maude=$1
root=$2
report=$(mktemp)
trap 'rm -f "$report"' EXIT

"$wasm2maude" suite-run "$root/test/i32_eqz.wast" \
  --semantics "$root/builtins.maude" --timeout 30 -o "$report"

grep -q '^PASS[[:space:]]' "$report"
grep -q 'i32_eqz.wast' "$report"

if "$wasm2maude" suite-run "$root/test/i32_eqz.wast" \
  --semantics "$root/builtins.maude" --timeout 30 --steps 1 -o "$report"
then
  echo "one-step suite run unexpectedly passed" >&2
  exit 1
fi

grep -q '^STEP_LIMIT[[:space:]]' "$report"
