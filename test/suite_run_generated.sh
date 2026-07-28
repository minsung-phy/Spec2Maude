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
