#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
bench="$root/benchmarks/wamr-multimodule-table-confusion"
out=${1:-"${TMPDIR:-/tmp}/spec2maude-wamr-table-confusion"}
mkdir -p "$out/modules"
cd "$root"

maude_bin=${MAUDE:-maude}
wamr_stable_ref=${WAMR_STABLE_REF:-WAMR-2.4.5}
wamr_main_ref=${WAMR_MAIN_REF:-97c7b8fd30b309abfe3a60b86bc5abb112fedbfa}

# ---------------------------------------------------------------------------
# 1. Compile the exact linked Wasm program and check it through the generated
#    SpecTec-to-Maude WebAssembly semantics.
# ---------------------------------------------------------------------------
for name in provider consumer; do
  wat2wasm "$bench/${name}.wat" -o "$out/modules/${name}.wasm"
  wasm-validate "$out/modules/${name}.wasm"

  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- module \
    "$bench/${name}.wat" --semantics builtins.maude \
    -o "$out/${name}-typecheck.maude"
  "$maude_bin" -no-banner "$out/${name}-typecheck.maude" \
    > "$out/${name}-typecheck.log" 2>&1
  grep -q 'result Bool: true' "$out/${name}-typecheck.log"
done

# Execute the linked WAST under the generated official WebAssembly semantics.
opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- wast-run \
  "$bench/case.wast" --semantics builtins.maude \
  --steps 4000000 --call-depth 256 \
  -o "$out/case.maude" 2> "$out/wast-emit.log"

"$maude_bin" -no-banner "$out/case.maude" \
  > "$out/spec2maude-execution.log" 2>&1

grep -q 'result ScriptState: script.done' "$out/spec2maude-execution.log"
if grep -Eq 'script\.(wrong-result|wrong-assertion|link-error)' \
    "$out/spec2maude-execution.log"; then
  cat "$out/spec2maude-execution.log" >&2
  exit 1
fi

# Explicit safety model check: provider.private-secret returning 1337 through
# the shared table is unreachable in the official core-Wasm transition system.
"$maude_bin" -no-banner "$out/case.maude" "$bench/modelcheck.maude" \
  > "$out/modelcheck.log" 2>&1

grep -q '^No solution\.' "$out/modelcheck.log"
grep -q 'result Bool: true' "$out/modelcheck.log"

# Independent standards-conforming engine oracle.
node "$bench/node_oracle.mjs" \
  "$out/modules/provider.wasm" "$out/modules/consumer.wasm" \
  > "$out/node-oracle.log" 2>&1
grep -q '^trapped=true$' "$out/node-oracle.log"

# ---------------------------------------------------------------------------
# 2. Run the unmodified, full WAMR runtime in documented multi-module mode.
#    We pin both the latest stable release and the current-main commit.  On
#    current main we exercise classic, fast, and GC-enabled interpreters.
# ---------------------------------------------------------------------------
checkout_wamr_ref() {
  local label=$1
  local ref=$2
  local src="$out/wamr-src-$label"

  rm -rf "$src"
  git clone --quiet https://github.com/wasm-micro-runtime/wasm-micro-runtime.git \
    "$src"
  git -C "$src" checkout --quiet "$ref"
  git -C "$src" rev-parse HEAD > "$out/wamr-$label.sha"
}

run_wamr_mode() {
  local source_label=$1
  local mode=$2
  local fast_interp=$3
  local gc=$4
  local src="$out/wamr-src-$source_label"
  local label="$source_label-$mode"
  local build="$out/wamr-$label-build"
  local log="$out/wamr-$label.log"

  rm -rf "$build"
  cmake -S "$bench" -B "$build" \
    -DWAMR_ROOT_DIR="$src" \
    -DWAMR_TEST_FAST_INTERP="$fast_interp" \
    -DWAMR_TEST_GC="$gc" \
    -DCMAKE_BUILD_TYPE=Release \
    > "$out/wamr-$label-cmake.log" 2>&1
  cmake --build "$build" --parallel 2 \
    > "$out/wamr-$label-build.log" 2>&1

  "$build/wamr-table-confusion" "$out/modules" > "$log" 2>&1
}

checkout_wamr_ref stable "$wamr_stable_ref"
checkout_wamr_ref main "$wamr_main_ref"

run_wamr_mode stable classic 0 0
run_wamr_mode main classic 0 0
run_wamr_mode main fast 1 0
run_wamr_mode main gc 0 1

classify_wamr() {
  local label=$1
  local log="$out/wamr-$label.log"

  if grep -q '^call_ok=1$' "$log" && grep -q '^result_i32=1337$' "$log"; then
    echo vulnerable
  elif grep -q '^call_ok=0$' "$log" \
       && grep -Eqi 'indirect call|type mismatch|signature' "$log"; then
    echo conforming
  else
    echo unexpected
  fi
}

stable_classic_status=$(classify_wamr stable-classic)
main_classic_status=$(classify_wamr main-classic)
main_fast_status=$(classify_wamr main-fast)
main_gc_status=$(classify_wamr main-gc)

{
  echo 'WAMR multi-module table function-origin experiment'
  echo '=================================================='
  echo "spec2maude_commit=$(git rev-parse HEAD)"
  echo "wamr_stable_ref=$wamr_stable_ref"
  echo "wamr_stable_commit=$(cat "$out/wamr-stable.sha")"
  echo "wamr_main_ref=$wamr_main_ref"
  echo "wamr_main_commit=$(cat "$out/wamr-main.sha")"
  echo
  echo '[Official semantics / independent oracle]'
  echo 'Spec2Maude linked WAST assertion: indirect type mismatch PASS'
  echo 'Spec2Maude search(private-secret-returned): No solution'
  echo 'Spec2Maude LTL [] ~ private-secret-returned: true'
  cat "$out/node-oracle.log"
  echo
  echo '[Unmodified full WAMR]'
  for label in stable-classic main-classic main-fast main-gc; do
    case "$label" in
      stable-classic) status=$stable_classic_status ;;
      main-classic) status=$main_classic_status ;;
      main-fast) status=$main_fast_status ;;
      main-gc) status=$main_gc_status ;;
    esac
    echo "${label}_status=$status"
    cat "$out/wamr-$label.log"
  done
  echo
  echo '[Maude statistics]'
  grep -E '^(rewrites:|states:|result (ScriptState|Bool|ModelCheckResult):)' \
    "$out/spec2maude-execution.log" "$out/modelcheck.log" || true
} | tee "$out/results.txt"

# The refs above are intentionally pinned.  A green run means the complete
# experiment reproduced the violation, rather than merely compiling the test.
for status in \
  "$stable_classic_status" \
  "$main_classic_status" \
  "$main_fast_status" \
  "$main_gc_status"; do
  if [[ "$status" != vulnerable ]]; then
    echo "expected vulnerable WAMR outcome, got: $status" >&2
    exit 1
  fi
done

echo "Artifacts written to $out"
