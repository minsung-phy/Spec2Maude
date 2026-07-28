set -eu

log=/tmp/spec2maude-wast-custom-syntax.log

if "$1" wast-run "$2" --semantics "$3" >"$log" 2>&1; then
  echo "custom-syntax WAST unexpectedly passed" >&2
  exit 1
fi
grep -Fq 'syntax error: misplaced annotation' "$log"
if grep -Fq 'Wasm.Custom.Syntax' "$log"; then
  sed -n '1,80p' "$log" >&2
  exit 1
fi
