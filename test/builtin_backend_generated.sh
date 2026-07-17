set -eu

exe=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
root=$(CDPATH= cd -- "$2" && pwd)
prefix=/tmp/spec2maude-builtin-backend-test
output="$prefix.maude"
builtins="$prefix-builtins.maude"
report="$prefix.md"
log="$prefix.log"
smoke_output="$prefix-smoke.maude"
smoke_builtins="$prefix-smoke-builtins.maude"
smoke_log="$prefix-smoke.log"
smoke_fixture="$root/test/builtin_backend_smoke.maude"
rm -f "$output" "$builtins" "$report" "$log" \
  "$smoke_output" "$smoke_builtins" "$smoke_log"

cd "$root"
if ! "$exe" translate -o "$output" --builtins "$builtins" \
    --builtin-report "$report" >"$log" 2>&1
then
  cat "$log" >&2
  echo 'builtin backend translation failed' >&2
  exit 1
fi
grep -q '\[spec2maude\] diagnostics: total=1289 fatal=0 unsupported=0 skipped=1289 obligations=0 prelude_gaps=0' "$log"
grep -q 'from contract config/wasm-3.0-runtime-ingress.contract:2' "$log"
grep -q 'from contract config/wasm-3.0-runtime-ingress.contract:3' "$log"
test -f "$output"
test -f "$builtins"
test -f "$report"

grep -q -- '- backend semantics: `official-spectec-deterministic`' "$report"
grep -q -- '- implemented: 87' "$report"
grep -q -- '- active obligations: 0' "$report"
grep -q -- '`builtin.ibits`' "$report"
if grep -Eq 'x5f|x[0-9A-Fa-f]{2}x|loc-' "$report"; then
  echo 'builtin report contains an obsolete generated operator spelling' >&2
  exit 1
fi
grep -q 'spectec/src/backend-interpreter/numerics.ml at revision d34a973e70ab127476b5d8591c6f558be289b929' "$report"
if grep -q '/Users/.*/spectec/src/backend-interpreter/numerics.ml' "$report"; then
  echo 'builtin report leaked a machine-absolute reference path' >&2
  exit 1
fi

if ! "$exe" translate -o "$smoke_output" --builtins "$smoke_builtins" \
    >"$smoke_log.translate" 2>&1
then
  cat "$smoke_log.translate" >&2
  echo 'builtin smoke translation failed' >&2
  exit 1
fi
test -f "$smoke_output"
test -f "$smoke_builtins"

if ! (cd /tmp && maude -no-banner "$(basename "$smoke_builtins")" \
      "$smoke_fixture") >"$smoke_log" 2>&1
then
  cat "$smoke_log" >&2
  exit 1
fi
if grep -E 'Warning:|Advisory:|Error:' "$smoke_log" >/dev/null; then
  cat "$smoke_log" >&2
  exit 1
fi
grep -q 'result' "$smoke_log"
