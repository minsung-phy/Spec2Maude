set -eu

output=$1

grep -Eq '^  ceq def\.memarg0 = rec\.memarg\(' "$output"
grep -Eq '^  ceq def\.allocdata\([^=]+\) = tuple\(compose\.rec\.store\(' "$output"
grep -Eq ' := rec\.moduleinst\(' "$output"
grep -Eq 'state\.sym\([^,]+, rec\.frame\(' "$output"
grep -Eq '^  ceq def\.invoke\([^=]+\) = config\.sym\(state\.sym\([^,]+, rec\.frame\(' "$output"
grep -Eq ' := rec\.taginst\(' "$output"

if grep -Fq 'merge(' "$output"; then
  echo 'generated output retained uninterpreted CompE merge' >&2
  exit 1
fi

if grep -Eq '= \{ .*item\(' "$output"; then
  echo 'generated record expression retained a generic record literal' >&2
  exit 1
fi
