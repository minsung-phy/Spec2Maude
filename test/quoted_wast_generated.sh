set -eu

wasm_exe=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
root=$(CDPATH= cd -- "$2" && pwd)

run_case() {
  name=$1
  fixture="$root/test/wast_quoted_$name.wast"
  harness="/tmp/spec2maude-quoted-$name.maude"
  log="/tmp/spec2maude-quoted-$name.log"

  "$wasm_exe" wast-run "$fixture" --semantics "$root/builtins.maude" \
    -o "$harness"
  if ! (cd "$root" && maude -no-banner "$harness") >"$log" 2>&1; then
    sed -n '1,200p' "$log" >&2
    exit 1
  fi
  if grep -E 'Warning:|Advisory:|Error:' "$log" >/dev/null; then
    sed -n '1,200p' "$log" >&2
    exit 1
  fi
  grep -q '^result ScriptState: script.done$' "$log"
}

run_case modules
run_case invalid
run_case malformed
