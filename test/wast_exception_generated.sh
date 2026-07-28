set -eu

wasm_exe=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
root=$(CDPATH= cd -- "$2" && pwd)
prefix=/tmp/spec2maude-exception-test

run_state() {
  name=$1
  expected=$2
  harness="$prefix-$name.maude"
  log="$prefix-$name.log"

  "$wasm_exe" wast-run "$root/test/$name.wast" \
    --semantics "$root/builtins.maude" --steps 100000 -o "$harness"
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

run_state wast_assert_exception_uncaught script.done
run_state wast_assert_exception_zero_result 'script.wrong-assertion(1)'
run_state wast_assert_exception_multiple_results 'script.wrong-assertion(1)'
run_state wast_assert_exception_trap 'script.wrong-assertion(1)'
run_state wast_assert_exception_caught 'script.wrong-assertion(1)'
