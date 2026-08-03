set -eu

exe=$(CDPATH= cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
root=$(CDPATH= cd -- "$2" && pwd)
wasm_exe=$(CDPATH= cd -- "$(dirname "$3")" && pwd)/$(basename "$3")
prefix=/tmp/spec2maude-runtime-truth-test
output="$prefix.maude"
builtins="$prefix-builtins.maude"
report="$prefix-builtins.md"
log="$prefix.log"
smoke_log="$prefix-smoke.log"
wasm_log="$prefix-wasm.log"
wasm_harness="$prefix-wasm.maude"
instantiate_log="$prefix-instantiate.log"
instantiate_harness="$prefix-instantiate.maude"
run_log="$prefix-run.log"
run_harness="$prefix-run.maude"
simd_log="$prefix-simd.log"
simd_harness="$prefix-simd.maude"
eqz_log="$prefix-eqz.log"
eqz_harness="$prefix-eqz.maude"
shift_log="$prefix-shift.log"
shift_harness="$prefix-shift.maude"
actions_log="$prefix-actions.log"
actions_harness="$prefix-actions.maude"
refs_log="$prefix-refs.log"
refs_harness="$prefix-refs.maude"
modules_log="$prefix-modules.log"
modules_harness="$prefix-modules.maude"
named_instances_log="$prefix-named-instances.log"
named_instances_harness="$prefix-named-instances.maude"
register_imports_log="$prefix-register-imports.log"
register_imports_harness="$prefix-register-imports.maude"
linking_subset_log="$prefix-linking-subset.log"
linking_subset_harness="$prefix-linking-subset.maude"
vectors_log="$prefix-vectors.log"
vectors_harness="$prefix-vectors.maude"
smoke_fixture="$root/test/runtime_truth_ref_ok_smoke.maude"
eqz_fixture="$root/test/i32_eqz.wast"
shift_fixture="$root/test/i64_shift.wast"
actions_fixture="$root/test/wast_actions.wast"
refs_fixture="$root/test/wast_refs.wast"
modules_fixture="$root/test/wast_modules.wast"
named_instances_fixture="$root/test/wast_named_instances.wast"
register_imports_fixture="$root/test/wast_register_imports.wast"
linking_subset_fixture="$root/test/wast_linking_function_subset.wast"
vectors_fixture="$root/test/wast_vectors.wast"

rm -f "$output" "$builtins" "$report" "$log" "$smoke_log" \
  "$wasm_log" "$wasm_harness" "$instantiate_log" "$instantiate_harness" \
  "$run_log" "$run_harness" "$simd_log" "$simd_harness"
rm -f "$eqz_log" "$eqz_harness"
rm -f "$shift_log" "$shift_harness"
rm -f "$actions_log" "$actions_harness"
rm -f "$refs_log" "$refs_harness"
rm -f "$modules_log" "$modules_harness"
rm -f "$named_instances_log" "$named_instances_harness"
rm -f "$register_imports_log" "$register_imports_harness"
rm -f "$linking_subset_log" "$linking_subset_harness"
rm -f "$vectors_log" "$vectors_harness"
cd "$root"
if ! "$exe" translate \
    -o "$output" --builtins "$builtins" --builtin-report "$report" \
    >"$log" 2>&1
then
  cat "$log" >&2
  echo 'source-complete target-chain translation failed' >&2
  exit 1
fi

grep -Eq '\[spec2maude\] diagnostics: total=[0-9]+ fatal=0 unsupported=0 skipped=[0-9]+ obligations=0 prelude_gaps=0' "$log"
grep -q 'target-chain-refute' "$output"
grep -q 'seed-ref-ok-rule-8' "$output"
grep -q 'truth-seed-miss-ref-ok' "$output"
grep -q 'seed-refute-8-source-boolean' "$output"
grep -q 'rule-refute-14-eq-pattern' "$output"
grep -Eq '_=/=_\(RTPAThelper[^,]*, TYPEUSE_STAR:SpectecTerminals\)' "$output"

assert_source_rule_order() {
  earlier=$1
  later=$2
  earlier_line=$(grep -n -m 1 "\[$earlier\]" "$output" | cut -d: -f1)
  later_line=$(grep -n -m 1 "\[$later\]" "$output" | cut -d: -f1)
  if [ "$earlier_line" -ge "$later_line" ]; then
    echo "generated execution rules reordered $earlier after $later" >&2
    exit 1
  fi
}

assert_source_rule_order step-read-ref-test-true step-read-ref-test-false
assert_source_rule_order step-read-ref-cast-succeed step-read-ref-cast-fail
if grep -Fq "_=/=_(index(value('TYPES'" "$output"; then
  echo 'type-index binding was emitted as a comparison against an unbound witness' >&2
  exit 1
fi

test -f "$output"
test -f "$builtins"
test -f "$report"

if ! (cd /tmp && maude -no-banner "$(basename "$builtins")" \
      "$smoke_fixture") >"$smoke_log" 2>&1
then
  cat "$smoke_log" >&2
  exit 1
fi
if grep -E 'Warning:|Advisory:|Error:' "$smoke_log" >/dev/null; then
  cat "$smoke_log" >&2
  exit 1
fi

assert_solution() {
  marker=$1
  section=$(awk -v begin="result Qid: '$marker-begin" \
    -v end="result Qid: '$marker-end" '
      $0 == begin { active = 1; next }
      $0 == end { active = 0; next }
      active { print }
    ' "$smoke_log")
  if [ "$(printf '%s\n' "$section" | grep -c '^Solution 1 ' || true)" -ne 1 ]; then
    cat "$smoke_log" >&2
    echo "$marker Ref_ok smoke search did not have exactly one solution" >&2
    exit 1
  fi
}

assert_solution ref-ok-positive
assert_solution ref-ok-negative
assert_solution ref-ok-no-seed

section_between() {
  marker=$1
  awk -v begin="result Qid: '$marker-begin" \
    -v end="result Qid: '$marker-end" '
      $0 == begin { active = 1; next }
      $0 == end { active = 0; next }
      active { print }
    ' "$smoke_log"
}

positive_subtype=$(section_between heaptype-sub-positive)
if ! printf '%s\n' "$positive_subtype" |
    grep -Fq 'helper.truth-proved.step-read'; then
  cat "$smoke_log" >&2
  echo 'recursive Heaptype_sub source path was not proved' >&2
  exit 1
fi

negative_subtype=$(section_between heaptype-sub-negative)
if printf '%s\n' "$negative_subtype" |
    grep -Fq 'helper.truth-refuted.step-read'; then
  cat "$smoke_log" >&2
  echo 'a true recursive Heaptype_sub source path was falsely refuted' >&2
  exit 1
fi

"$wasm_exe" module "$root/wat_examples/fib-wrapper.wat" \
  --semantics "$builtins" -o "$wasm_harness"
if ! maude -no-banner "$wasm_harness" >"$wasm_log" 2>&1; then
  cat "$wasm_log" >&2
  exit 1
fi
if grep -E 'Warning:|Advisory:|Error:' "$wasm_log" >/dev/null; then
  cat "$wasm_log" >&2
  exit 1
fi
grep -q '^result Bool: true$' "$wasm_log"

"$wasm_exe" instantiate "$root/wat_examples/fib-wrapper.wat" \
  --semantics "$builtins" -o "$instantiate_harness"
if ! maude -no-banner "$instantiate_harness" >"$instantiate_log" 2>&1; then
  cat "$instantiate_log" >&2
  exit 1
fi
if grep -E 'Warning:|Advisory:|Error:' "$instantiate_log" >/dev/null; then
  cat "$instantiate_log" >&2
  exit 1
fi
grep -q '^result SpectecTerminal: config.sym' "$instantiate_log"

"$wasm_exe" run "$root/wat_examples/fib-wrapper.wat" \
  --invoke fib --arg i32:5 --arg i32:0 --arg i32:1 \
  --semantics "$builtins" -o "$run_harness"
if ! maude -no-banner "$run_harness" >"$run_log" 2>&1; then
  cat "$run_log" >&2
  exit 1
fi
if grep -E 'Warning:|Advisory:|Error:' "$run_log" >/dev/null; then
  cat "$run_log" >&2
  exit 1
fi
tr '\n' ' ' <"$run_log" | grep -Eq \
  'result RunState: exec\(config\.sym\(.*instr\.const\([[:space:]]*numtype\.i32,[[:space:]]*uN\.wrap\([[:space:]]*5\)\)\)\)'

run_example() {
  name=$1
  input=$2
  expected=$3
  harness="$prefix-$name.maude"
  example_log="$prefix-$name.log"

  "$wasm_exe" run "$input" --invoke main \
    --semantics "$builtins" -o "$harness"
  if ! maude -no-banner "$harness" >"$example_log" 2>&1; then
    cat "$example_log" >&2
    exit 1
  fi
  if grep -E 'Warning:|Advisory:|Error:' "$example_log" >/dev/null; then
    cat "$example_log" >&2
    exit 1
  fi
  tr '\n' ' ' <"$example_log" | grep -Eq \
    "result RunState: exec\\(config\\.sym\\(.*instr\\.const\\([[:space:]]*numtype\\.i32,[[:space:]]*uN\\.wrap\\([[:space:]]*$expected\\)\\)\\)\\)"
}

run_example data-load "$root/wat_examples/data-load.wat" 42
run_example memory-zero-load "$root/wat_examples/memory-zero-load.wat" 0
run_example global-get "$root/wat_examples/global-get.wat" 42
run_example table-size "$root/wat_examples/table-size.wat" 3
run_example elem-call-ref "$root/wat_examples/elem-call-ref.wat" 9
run_example start-global "$root/wat_examples/start-global.wat" 7

run_wast_state() {
  name=$1
  fixture=$2
  expected=$3
  harness="$prefix-$name.maude"
  fixture_log="$prefix-$name.log"

  "$wasm_exe" wast-run "$fixture" --semantics "$builtins" -o "$harness"
  if ! maude -no-banner "$harness" >"$fixture_log" 2>&1; then
    cat "$fixture_log" >&2
    exit 1
  fi
  if grep -E 'Warning:|Advisory:|Error:' "$fixture_log" >/dev/null; then
    cat "$fixture_log" >&2
    exit 1
  fi
  grep -Fq "result ScriptState: $expected" "$fixture_log"
  if [ "$expected" = script.wrong-result ] &&
      grep -q '^result ScriptState: script.return' "$fixture_log"; then
    cat "$fixture_log" >&2
    exit 1
  fi
}

"$wasm_exe" wast-run "$eqz_fixture" \
  --semantics "$builtins" -o "$eqz_harness"
if ! maude -no-banner "$eqz_harness" >"$eqz_log" 2>&1; then
  cat "$eqz_log" >&2
  exit 1
fi
if grep -E 'Warning:|Advisory:|Error:' "$eqz_log" >/dev/null; then
  cat "$eqz_log" >&2
  exit 1
fi
grep -q '^result ScriptState: script.done$' "$eqz_log"

"$wasm_exe" wast-run "$shift_fixture" \
  --semantics "$builtins" -o "$shift_harness"
if ! maude -no-banner "$shift_harness" >"$shift_log" 2>&1; then
  cat "$shift_log" >&2
  exit 1
fi
if grep -E 'Warning:|Advisory:|Error:' "$shift_log" >/dev/null; then
  cat "$shift_log" >&2
  exit 1
fi
grep -q '^result ScriptState: script.done$' "$shift_log"

"$wasm_exe" wast-run "$actions_fixture" \
  --semantics "$builtins" -o "$actions_harness"
if ! maude -no-banner "$actions_harness" >"$actions_log" 2>&1; then
  cat "$actions_log" >&2
  exit 1
fi
if grep -E 'Warning:|Advisory:|Error:' "$actions_log" >/dev/null; then
  cat "$actions_log" >&2
  exit 1
fi
grep -q '^result ScriptState: script.done$' "$actions_log"

"$wasm_exe" wast-run "$refs_fixture" \
  --semantics "$builtins" -o "$refs_harness"
if ! maude -no-banner "$refs_harness" >"$refs_log" 2>&1; then
  cat "$refs_log" >&2
  exit 1
fi
if grep -E 'Warning:|Advisory:|Error:' "$refs_log" >/dev/null; then
  cat "$refs_log" >&2
  exit 1
fi
grep -q '^result ScriptState: script.done$' "$refs_log"

"$wasm_exe" wast-run "$modules_fixture" \
  --semantics "$builtins" -o "$modules_harness"
if ! maude -no-banner "$modules_harness" >"$modules_log" 2>&1; then
  cat "$modules_log" >&2
  exit 1
fi
if grep -E 'Warning:|Advisory:|Error:' "$modules_log" >/dev/null; then
  cat "$modules_log" >&2
  exit 1
fi
grep -q '^result ScriptState: script.done$' "$modules_log"

"$wasm_exe" wast-run "$named_instances_fixture" \
  --semantics "$builtins" -o "$named_instances_harness"
if ! maude -no-banner "$named_instances_harness" \
    >"$named_instances_log" 2>&1; then
  cat "$named_instances_log" >&2
  exit 1
fi
if grep -E 'Warning:|Advisory:|Error:' \
    "$named_instances_log" >/dev/null; then
  cat "$named_instances_log" >&2
  exit 1
fi
grep -q '^result ScriptState: script.done$' "$named_instances_log"

"$wasm_exe" wast-run "$register_imports_fixture" \
  --semantics "$builtins" -o "$register_imports_harness"
if ! maude -no-banner "$register_imports_harness" \
    >"$register_imports_log" 2>&1; then
  cat "$register_imports_log" >&2
  exit 1
fi
if grep -E 'Warning:|Advisory:|Error:' \
    "$register_imports_log" >/dev/null; then
  cat "$register_imports_log" >&2
  exit 1
fi
grep -q '^result ScriptState: script.done$' "$register_imports_log"

"$wasm_exe" wast-run "$linking_subset_fixture" \
  --semantics "$builtins" -o "$linking_subset_harness"
if ! maude -no-banner "$linking_subset_harness" \
    >"$linking_subset_log" 2>&1; then
  cat "$linking_subset_log" >&2
  exit 1
fi
if grep -E 'Warning:|Advisory:|Error:' \
    "$linking_subset_log" >/dev/null; then
  cat "$linking_subset_log" >&2
  exit 1
fi
grep -q '^result ScriptState: script.done$' "$linking_subset_log"

"$wasm_exe" wast-run "$vectors_fixture" \
  --semantics "$builtins" -o "$vectors_harness"
if ! maude -no-banner "$vectors_harness" >"$vectors_log" 2>&1; then
  cat "$vectors_log" >&2
  exit 1
fi
if grep -E 'Warning:|Advisory:|Error:' "$vectors_log" >/dev/null; then
  cat "$vectors_log" >&2
  exit 1
fi
grep -q '^result ScriptState: script.done$' "$vectors_log"

run_wast_state result-patterns "$root/test/wast_result_patterns.wast" \
  script.done
run_wast_state vector-nan-lanes "$root/test/wast_vector_nan_lanes.wast" \
  script.done
run_wast_state spectest-print "$root/test/wast_spectest_print_completes.wast" \
  script.done
run_wast_state spectest-global "$root/test/wast_spectest_global_i32_value.wast" \
  script.done
run_wast_state spectest-memory "$root/test/wast_spectest_memory_shared.wast" \
  script.done
run_wast_state spectest-tables "$root/test/wast_spectest_tables_shared.wast" \
  script.done
run_wast_state spectest-register-override \
  "$root/test/wast_spectest_register_override.wast" script.done
run_wast_state wrong-invoke "$root/test/wast_wrong_invoke.wast" \
  script.wrong-result
run_wast_state wrong-get "$root/test/wast_wrong_get.wast" \
  script.wrong-result
run_wast_state wrong-nan "$root/test/wast_wrong_nan.wast" \
  script.wrong-result
run_wast_state wrong-nan-arithmetic \
  "$root/test/wast_wrong_nan_arithmetic.wast" script.wrong-result
run_wast_state wrong-null "$root/test/wast_wrong_null.wast" \
  script.wrong-result
run_wast_state wrong-reftype "$root/test/wast_wrong_reftype.wast" \
  script.wrong-result
run_wast_state wrong-either "$root/test/wast_wrong_either.wast" \
  script.wrong-result
run_wast_state wrong-vector-signaling-nan \
  "$root/test/wast_wrong_vector_signaling_nan.wast" script.wrong-result
run_wast_state wrong-vector-canonical-nan \
  "$root/test/wast_wrong_vector_canonical_nan.wast" script.wrong-result
run_wast_state wrong-vector-exact-lane \
  "$root/test/wast_wrong_vector_exact_lane.wast" script.wrong-result

"$wasm_exe" module "$root/wat_examples/simd-special.wat" \
  --semantics "$builtins" -o "$simd_harness"
if ! maude -no-banner "$simd_harness" >"$simd_log" 2>&1; then
  cat "$simd_log" >&2
  exit 1
fi
if grep -E 'Warning:|Advisory:|Error:' "$simd_log" >/dev/null; then
  cat "$simd_log" >&2
  exit 1
fi
grep -q '^result Bool: true$' "$simd_log"
