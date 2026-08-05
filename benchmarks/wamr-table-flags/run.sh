#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
bench="$root/benchmarks/wamr-table-flags"
out=${1:-"${TMPDIR:-/tmp}/spec2maude-wamr-table-flags"}
mkdir -p "$out"
cd "$root"

maude_bin=${MAUDE:-maude}
wamr_sha=${WAMR_SHA:-70f4cd383f1a474d6759e3185b4eca6f6ddde4d4}
wamr="$out/wasm-micro-runtime"
git clone --quiet https://github.com/wasm-micro-runtime/wasm-micro-runtime.git "$wamr"
git -C "$wamr" checkout --quiet "$wamr_sha"
actual_sha=$(git -C "$wamr" rev-parse HEAD)
test "$actual_sha" = "$wamr_sha"

python3 "$bench/prepare_sources.py" \
  "$wamr/core/iwasm/common/wasm_loader_common.c" "$out/extracted"
diff -u "$out/extracted/current.c" "$out/extracted/fixed.c" \
  > "$out/table-shared-fix.patch" || true

for mode in current fixed; do
  cc -O2 -Wall -Wextra -Werror -DWAMR_TABLE_NATIVE_MAIN \
    "$out/extracted/${mode}.c" -o "$out/${mode}-native"
  "$out/${mode}-native" > "$out/${mode}-native.log"

done
grep -q '^mismatch_count=2$' "$out/current-native.log"
grep -q '^flag_2=1$' "$out/current-native.log"
grep -q '^flag_3=1$' "$out/current-native.log"
grep -q '^mismatch_count=0$' "$out/fixed-native.log"

for mode in current fixed; do
  clang --target=wasm32-unknown-unknown -O2 -nostdlib \
    "$out/extracted/${mode}.c" -Wl,--no-entry \
    -Wl,--export=wamr_table_flag_accept -Wl,--export-memory \
    -o "$out/wamr-table-${mode}.wasm"

  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- module \
    "$out/wamr-table-${mode}.wasm" --semantics builtins.maude \
    -o "$out/${mode}-typecheck.maude"
  "$maude_bin" -no-banner "$out/${mode}-typecheck.maude" \
    > "$out/${mode}-typecheck.log" 2>&1
  grep -q 'result Bool: true' "$out/${mode}-typecheck.log"

  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- run \
    "$out/wamr-table-${mode}.wasm" --invoke wamr_table_flag_accept \
    --arg i32:2 --steps 500000 --semantics builtins.maude \
    -o "$out/${mode}-flag2.maude"
  "$maude_bin" -no-banner "$out/${mode}-flag2.maude" \
    > "$out/${mode}-flag2.log" 2>&1

  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- run \
    "$out/wamr-table-${mode}.wasm" --invoke wamr_table_flag_accept \
    --arg i32:0 --steps 500000 --semantics builtins.maude \
    -o "$out/${mode}-base.maude"
  python3 "$bench/make_modelcheck.py" "$out/${mode}-base.maude" \
    "$out/${mode}-modelcheck.maude" \
    --module-name "WAMR-TABLE-${mode^^}-MC"
  "$maude_bin" -no-banner "$out/${mode}-modelcheck.maude" \
    > "$out/${mode}-modelcheck.log" 2>&1
done

grep -q 'instr.const(numtype.i32, uN.wrap(1))' "$out/current-flag2.log"
grep -q 'instr.const(numtype.i32, uN.wrap(0))' "$out/fixed-flag2.log"
grep -q '^Solution 1' "$out/current-modelcheck.log"
grep -q 'result ModelCheckResult: counterexample' "$out/current-modelcheck.log"
grep -q '^No solution\.' "$out/fixed-modelcheck.log"
grep -q 'result Bool: true' "$out/fixed-modelcheck.log"

python3 "$bench/generate_modules.py" "$out/modules" \
  > "$out/generated-modules.log"
for flag in 0 1 4 5; do
  wasm-validate --enable-memory64 "$out/modules/table-flag-${flag}.wasm" \
    > "$out/wabt-flag-${flag}.log" 2>&1
done
for flag in 2 3; do
  set +e
  wasm-validate --enable-memory64 "$out/modules/table-flag-${flag}.wasm" \
    > "$out/wabt-flag-${flag}.log" 2>&1
  rc=$?
  set -e
  test "$rc" -ne 0
done

cmake_args=(
  -DWAMR_BUILD_MEMORY64=1
  -DWAMR_BUILD_AOT=0
  -DWAMR_BUILD_JIT=0
  -DWAMR_BUILD_FAST_JIT=0
  -DWAMR_BUILD_SIMD=0
  -DWAMR_BUILD_LIBC_WASI=0
  -DCMAKE_BUILD_TYPE=Release
)
cmake -S "$wamr/product-mini/platforms/linux" -B "$out/current-build" \
  "${cmake_args[@]}" > "$out/current-cmake.log" 2>&1
cmake --build "$out/current-build" --parallel 2 > "$out/current-build.log" 2>&1

run_module() {
  local exe=$1 module=$2 log=$3
  set +e
  timeout 20s "$exe" "$module" > "$log" 2>&1
  local rc=$?
  set -e
  echo "$rc"
}

for flag in 0 1 2 3 4 5; do
  rc=$(run_module "$out/current-build/iwasm" \
    "$out/modules/table-flag-${flag}.wasm" "$out/current-flag-${flag}.log")
  echo "$rc" > "$out/current-flag-${flag}.rc"
done

python3 - "$wamr/core/iwasm/common/wasm_loader_common.c" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = '''        if (table_flag & SHARED_TABLE_FLAG) {
            wasm_loader_set_error_buf(error_buf, error_buf_size,
                                      "tables cannot be shared", is_aot);
        }
'''
new = '''        if (table_flag & SHARED_TABLE_FLAG) {
            wasm_loader_set_error_buf(error_buf, error_buf_size,
                                      "tables cannot be shared", is_aot);
            return false;
        }
'''
if s.count(old) != 1:
    raise SystemExit('shared-table branch not found')
p.write_text(s.replace(old, new, 1))
PY

cmake -S "$wamr/product-mini/platforms/linux" -B "$out/fixed-build" \
  "${cmake_args[@]}" > "$out/fixed-cmake.log" 2>&1
cmake --build "$out/fixed-build" --parallel 2 > "$out/fixed-build.log" 2>&1
for flag in 0 1 2 3 4 5; do
  rc=$(run_module "$out/fixed-build/iwasm" \
    "$out/modules/table-flag-${flag}.wasm" "$out/fixed-flag-${flag}.log")
  echo "$rc" > "$out/fixed-flag-${flag}.rc"
done

{
  echo 'WAMR reserved table flag model-checking result'
  echo '================================================'
  echo "spec2maude_commit=$(git rev-parse HEAD)"
  echo "wamr_commit=$actual_sha"
  echo
  echo '[Exact production predicate]'
  cat "$out/current-native.log"
  echo
  echo '[One-line repair]'
  cat "$out/fixed-native.log"
  echo
  echo '[Spec2Maude model checking]'
  grep -E '^(Solution 1|No solution\.|states:|rewrites:|result (Bool|ModelCheckResult):)' \
    "$out/current-modelcheck.log" "$out/fixed-modelcheck.log" || true
  echo
  echo '[Full WAMR loader exit codes]'
  for flag in 0 1 2 3 4 5; do
    echo "current_flag_${flag}_rc=$(cat "$out/current-flag-${flag}.rc")"
  done
  for flag in 0 1 2 3 4 5; do
    echo "fixed_flag_${flag}_rc=$(cat "$out/fixed-flag-${flag}.rc")"
  done
} | tee "$out/results.txt"

for flag in 0 1 2 3 4 5; do
  test "$(cat "$out/current-flag-${flag}.rc")" -eq 0
done
for flag in 0 1 4 5; do
  test "$(cat "$out/fixed-flag-${flag}.rc")" -eq 0
done
for flag in 2 3; do
  test "$(cat "$out/fixed-flag-${flag}.rc")" -ne 0
done
