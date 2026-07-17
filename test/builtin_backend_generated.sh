set -eu

exe=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
root=$(CDPATH= cd -- "$2" && pwd)
subset_exe=$(CDPATH= cd -- "$(dirname "$3")" && pwd)/$(basename "$3")
prefix=/tmp/spec2maude-builtin-backend-test
output="$prefix.maude"
builtins="$prefix-builtins.maude"
report="$prefix.md"
log="$prefix.log"
smoke_output="$prefix-smoke.maude"
smoke_builtins="$prefix-smoke-builtins.maude"
smoke_log="$prefix-smoke.log"
smoke_translate_log="$prefix-smoke-translate.log"
smoke_fixture="$root/test/builtin_backend_smoke.maude"
rm -f "$output" "$builtins" "$report" "$log" \
  "$smoke_output" "$smoke_builtins" "$smoke_log" "$smoke_translate_log"

cd "$root"
set +e
"$exe" translate -o "$output" --builtins "$builtins" \
  --builtin-report "$report" >"$log" 2>&1
translate_status=$?
set -e
if [ "$translate_status" -ne 1 ]; then
  cat "$log" >&2
  echo "production builtin report translation exited $translate_status, expected 1" >&2
  exit 1
fi
grep -Eq '^\[spec2maude\] diagnostics: .*fatal=[1-9][0-9]* unsupported=[1-9][0-9]* .*obligations=0 prelude_gaps=0' "$log"
grep -q 'from contract config/wasm-3.0-runtime-ingress.contract:2' "$log"
grep -q 'from contract config/wasm-3.0-runtime-ingress.contract:3' "$log"
test ! -e "$output"
test ! -e "$builtins"
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

if ! "$subset_exe" "$smoke_output" "$smoke_builtins" \
    "$root"/wasm-3.0/0.*.spectec \
    "$root"/wasm-3.0/1.*.spectec \
    "$root"/wasm-3.0/3.*.spectec \
    "$root"/wasm-3.0/4.0-execution.configurations.spectec \
    >"$smoke_translate_log" 2>&1
then
  cat "$smoke_translate_log" >&2
  echo 'builtin smoke translation failed' >&2
  exit 1
fi
grep -Eq '^\[spec2maude\] diagnostics: .*fatal=0 unsupported=0' "$smoke_translate_log"
test -f "$smoke_output"
test -f "$smoke_builtins"
if grep -q '^--- PARTIAL/INCOMPLETE VERIFICATION' "$smoke_output" "$smoke_builtins"; then
  echo 'complete builtin smoke subset was marked partial' >&2
  exit 1
fi

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

smoke_compact=$(tr -d '[:space:]' <"$smoke_log")
rolldt_subtype='subtype.sub(eps, eps, comptype.func-sym(list.wrap(eps), list.wrap(eps)))'
rolldt_rectype="rectype.rec(list.wrap($rolldt_subtype $rolldt_subtype))"
rolldt_result="result SpectecTerminals: deftype.def($rolldt_rectype, 0) deftype.def($rolldt_rectype, 1)"
rolldt_result_compact=$(printf '%s' "$rolldt_result" | tr -d '[:space:]')
if ! printf '%s\n' "$smoke_compact" | grep -Fq "$rolldt_result_compact"; then
  cat "$smoke_log" >&2
  echo 'rolldt smoke did not preserve the original subtype sequence while producing indices 0 and 1' >&2
  exit 1
fi
