set -eu

wasm_exe=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
root=$(CDPATH= cd -- "$2" && pwd)
prefix=/tmp/spec2maude-uninstantiable-test

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

run_state wast_assert_uninstantiable_trap script.done
run_state wast_assert_uninstantiable_normal 'script.wrong-assertion(1)'
run_state wast_assert_uninstantiable_static 'script.wrong-assertion(1)'
run_state wast_assert_uninstantiable_static_incompatible 'script.wrong-assertion(1)'
run_state wast_assert_uninstantiable_live_link_error 'script.wrong-assertion(1)'
run_state wast_assert_uninstantiable_memory script.done
run_state wast_assert_uninstantiable_exception script.done
