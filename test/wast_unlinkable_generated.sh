set -eu

wasm_exe=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
root=$(CDPATH= cd -- "$2" && pwd)
prefix=/tmp/spec2maude-unlinkable-test

run_state() {
  name=$1
  expected=$2
  fixture="$root/test/$name.wast"
  harness="$prefix-$name.maude"
  log="$prefix-$name.log"

  "$wasm_exe" wast-run "$fixture" --semantics "$root/builtins.maude" \
    --steps 100000 -o "$harness"
  if ! maude -no-banner "$harness" >"$log" 2>&1; then
    sed -n '1,240p' "$log" >&2
    exit 1
  fi
  if grep -E 'Warning:|Advisory:|Error:' "$log" >/dev/null; then
    sed -n '1,240p' "$log" >&2
    exit 1
  fi
  grep -Fq "result ScriptState: $expected" "$log"
}

run_state wast_assert_unlinkable_static script.done
run_state wast_assert_unlinkable_live_before script.done
run_state wast_assert_unlinkable_live_transition 'script.wrong-assertion(4)'
run_state wast_assert_unlinkable_linkable 'script.wrong-assertion(1)'
run_state wast_assert_unlinkable_start_trap 'script.wrong-assertion(1)'
