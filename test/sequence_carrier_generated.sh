#!/bin/sh
set -eu

output=$1

grep -Fq \
  'ceq helper.iter-count.allocmem(s COUNT1:Nat, I:SpectecTerminal) = canonicalRun(s COUNT1:Nat, OUTPUT1:SpectecTerminal)' \
  "$output"
grep -Fq \
  'ceq helper.iter-count.growmem(s COUNT1:Nat) = canonicalRun(s COUNT1:Nat, OUTPUT1:SpectecTerminal)' \
  "$output"

if ! grep -F 'ceq def.with-mem' "$output" \
    | grep -Fq "'BYTES <- spliceRun"
then
  echo 'selected SliceP carrier did not use spliceRun' >&2
  exit 1
fi

if grep -F 'helper.iter-count.alloctable' "$output" \
    | grep -Fq '= canonicalRun('
then
  echo 'an unrelated ListN helper was switched to canonical runs' >&2
  exit 1
fi

test "$(grep -c 'helper\.iter-count\..*= canonicalRun' "$output")" -eq 2
