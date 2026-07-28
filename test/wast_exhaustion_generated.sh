set -eu

wasm_exe=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
root=$(CDPATH= cd -- "$2" && pwd)
prefix=/tmp/spec2maude-exhaustion-test

run_state() {
  name=$1
  depth=$2
  steps=$3
  expected=$4
  harness="$prefix-$name-$depth.maude"
  log="$prefix-$name-$depth.log"

  "$wasm_exe" wast-run "$root/test/$name.wast" \
    --semantics "$root/builtins.maude" --steps "$steps" \
    --call-depth "$depth" -o "$harness"
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

run_state wast_assert_exhaustion_recursive 2 100000 script.done
run_state wast_assert_exhaustion_num_prefix 1 100000 script.done
run_state wast_assert_exhaustion_vector_prefix 1 100000 script.done
run_state wast_assert_exhaustion_ref_prefix 1 100000 script.done
run_state wast_assert_exhaustion_store_continuation 2 100000 script.done
run_state wast_assert_exhaustion_finite 2 100000 'script.wrong-assertion(1)'
run_state wast_assert_exhaustion_zero 0 100000 script.done
run_state wast_assert_exhaustion_zero 1 100000 'script.wrong-assertion(1)'
run_state wast_assert_exhaustion_one 1 100000 'script.wrong-assertion(1)'
run_state wast_assert_exhaustion_multiple 1 100000 'script.wrong-assertion(1)'
run_state wast_assert_exhaustion_trap 1 100000 'script.wrong-assertion(1)'
run_state wast_assert_exhaustion_exception 1 100000 'script.wrong-assertion(1)'
run_state wast_assert_exhaustion_loop 1 50 'script.exhaustion(1, 1,'
run_state wast_assert_exhaustion_tail 1 50 'script.exhaustion(1, 1,'

observer_harness="$prefix-wast_assert_exhaustion_num_prefix-1.maude"
grep -Fq 'activeFrameDepth(instr.const(NT, VALUE) REST)' "$observer_harness"
grep -Fq 'instr.vconst(vectype.v128, C) REST) = activeFrameDepth(REST)' \
  "$observer_harness"
grep -Fq 'if typecheck(C, syn.ref) .' "$observer_harness"
if grep -Fq 'if typecheck(C, syn.val) .' "$observer_harness"; then
  echo 'activeFrameDepth still skips semantic syn.val terms' >&2
  exit 1
fi

default_harness="$prefix-default.maude"
override_harness="$prefix-override.maude"
"$wasm_exe" wast-run "$root/test/wast_assert_exhaustion_zero.wast" \
  --semantics "$root/builtins.maude" --steps 1 -o "$default_harness"
grep -Fq 'command.exhaustion(1, 256,' "$default_harness"
"$wasm_exe" wast-run "$root/test/wast_assert_exhaustion_zero.wast" \
  --semantics "$root/builtins.maude" --steps 1 --call-depth 2 \
  -o "$override_harness"
grep -Fq 'command.exhaustion(1, 2,' "$override_harness"

for invalid in -1 nope; do
  log="$prefix-invalid-$invalid.log"
  if "$wasm_exe" wast-run "$root/test/wast_assert_exhaustion_zero.wast" \
      --semantics "$root/builtins.maude" --call-depth "$invalid" \
      >"$log" 2>&1; then
    echo "invalid --call-depth $invalid unexpectedly succeeded" >&2
    exit 1
  fi
  grep -Fq 'usage:' "$log"
done
