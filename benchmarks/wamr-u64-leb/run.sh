#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
bench="$root/benchmarks/wamr-u64-leb"
out_dir=${1:-"${TMPDIR:-/tmp}/spec2maude-wamr-u64-leb"}
mkdir -p "$out_dir"
cd "$root"

maude_bin=${MAUDE:-maude}
wamr_sha=${WAMR_SHA:-70f4cd383f1a474d6759e3185b4eca6f6ddde4d4}
wamr_dir="$out_dir/wasm-micro-runtime"

apply_u64_fix() {
  local file=$1
  python3 - "$file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = """    if (!sign && maxbits == 32 && shift >= maxbits) {
        /* The top bits set represent values > 32 bits */
        if (((uint8)byte) & 0xf0)
            return BH_LEB_READ_OVERFLOW;
    }
    else if (sign && maxbits == 32) {
"""
new = """    if (!sign && maxbits == 32 && shift >= maxbits) {
        /* The top bits set represent values > 32 bits */
        if (((uint8)byte) & 0xf0)
            return BH_LEB_READ_OVERFLOW;
    }
    else if (!sign && maxbits == 64 && shift >= maxbits) {
        /* A ten-byte u64 LEB may use only bit 0 of its final payload. */
        if (((uint8)byte) & 0xfe)
            return BH_LEB_READ_OVERFLOW;
    }
    else if (sign && maxbits == 32) {
"""
if text.count(old) != 1:
    raise SystemExit("expected WAMR unsigned-32 overflow block was not found")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
PY
}

run_iwasm() {
  local binary=$1
  local module=$2
  local log=$3
  set +e
  timeout 20s "$binary" "$module" > "$log" 2>&1
  local rc=$?
  set -e
  printf '%s\n' "$rc"
}

printf 'Cloning WAMR %s\n' "$wamr_sha"
git clone --quiet https://github.com/wasm-micro-runtime/wasm-micro-runtime.git "$wamr_dir"
git -C "$wamr_dir" checkout --quiet "$wamr_sha"
actual_wamr_sha=$(git -C "$wamr_dir" rev-parse HEAD)
test "$actual_wamr_sha" = "$wamr_sha"

current_src="$out_dir/current-src"
fixed_src="$out_dir/fixed-src"
mkdir -p "$current_src" "$fixed_src"
cp "$wamr_dir/core/shared/utils/bh_leb128.c" \
   "$wamr_dir/core/shared/utils/bh_leb128.h" "$current_src/"
cp "$current_src/bh_leb128.c" "$current_src/bh_leb128.h" "$fixed_src/"
apply_u64_fix "$fixed_src/bh_leb128.c"

diff -u "$current_src/bh_leb128.c" "$fixed_src/bh_leb128.c" \
  > "$out_dir/u64-overflow-fix.patch" || true

# Native execution of the exact pinned production decoder.
cc -O2 -Wall -Wextra -Werror -DWAMR_LEB_NATIVE_MAIN \
  -I "$current_src" "$bench/wrapper.c" -o "$out_dir/current-native"
cc -O2 -Wall -Wextra -Werror -DWAMR_LEB_NATIVE_MAIN \
  -I "$fixed_src" "$bench/wrapper.c" -o "$out_dir/fixed-native"
"$out_dir/current-native" > "$out_dir/current-native.log"
"$out_dir/fixed-native" > "$out_dir/fixed-native.log"

grep -q '^mismatch_count=126$' "$out_dir/current-native.log"
grep -q '^status_last_2=0$' "$out_dir/current-native.log"
grep -q '^value_last_2=0$' "$out_dir/current-native.log"
grep -q '^mismatch_count=0$' "$out_dir/fixed-native.log"
grep -q '^status_last_2=2$' "$out_dir/fixed-native.log"

# Compile the same production C decoder to a standalone Wasm program.  This is
# the real WAMR source at the pinned commit; wrapper.c only supplies an export.
compile_wasm() {
  local src_dir=$1
  local output=$2
  clang --target=wasm32-unknown-unknown -O2 -nostdlib \
    -I "$src_dir" "$bench/wrapper.c" \
    -Wl,--no-entry \
    -Wl,--export=wamr_decode_status \
    -Wl,--export=wamr_decode_value \
    -Wl,--export-memory \
    -o "$output"
}

compile_wasm "$current_src" "$out_dir/wamr-leb-current.wasm"
compile_wasm "$fixed_src" "$out_dir/wamr-leb-fixed.wasm"

for mode in current fixed; do
  wasm="$out_dir/wamr-leb-${mode}.wasm"
  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- module \
    "$wasm" --semantics builtins.maude \
    -o "$out_dir/${mode}-typecheck.maude"
  "$maude_bin" -no-banner "$out_dir/${mode}-typecheck.maude" \
    > "$out_dir/${mode}-typecheck.log" 2>&1
  grep -q 'result Bool: true' "$out_dir/${mode}-typecheck.log"

  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- run \
    "$wasm" --invoke wamr_decode_status --arg i32:2 \
    --steps 500000 --call-depth 128 --semantics builtins.maude \
    -o "$out_dir/${mode}-last2.maude"
  "$maude_bin" -no-banner "$out_dir/${mode}-last2.maude" \
    > "$out_dir/${mode}-last2.log" 2>&1

done

grep -q 'instr.const(numtype.i32, uN.wrap(0))' \
  "$out_dir/current-last2.log"
grep -q 'instr.const(numtype.i32, uN.wrap(2))' \
  "$out_dir/fixed-last2.log"

# Emit parameterized transition systems and explore all 128 possible terminal
# payload bytes using Maude reachability and LTL model checking.
for mode in current fixed; do
  wasm="$out_dir/wamr-leb-${mode}.wasm"
  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- run \
    "$wasm" --invoke wamr_decode_status --arg i32:0 \
    --steps 500000 --call-depth 128 --semantics builtins.maude \
    -o "$out_dir/${mode}-base.maude"
  python3 "$bench/make_modelcheck.py" \
    "$out_dir/${mode}-base.maude" "$out_dir/${mode}-modelcheck.maude" \
    --module-name "WAMR-LEB-${mode^^}-MC" --max-last 127
  "$maude_bin" -no-banner "$out_dir/${mode}-modelcheck.maude" \
    > "$out_dir/${mode}-modelcheck.log" 2>&1

done

grep -q '^Solution 1' "$out_dir/current-modelcheck.log"
grep -q 'result ModelCheckResult: counterexample' \
  "$out_dir/current-modelcheck.log"
grep -q '^No solution\.' "$out_dir/fixed-modelcheck.log"
grep -q 'result Bool: true' "$out_dir/fixed-modelcheck.log"

# Full production-loader impact: build WAMR with the phase-4 memory64 feature
# and feed it a malformed module whose u64 minimum uses a forbidden final
# payload.  A conforming validator rejects the module before instantiation.
python3 "$bench/generate_modules.py" "$out_dir/modules" \
  > "$out_dir/generated-modules.log"

control="$out_dir/modules/memory64-valid-zero.wasm"
overflow2="$out_dir/modules/memory64-overflow-2.wasm"
overflow127="$out_dir/modules/memory64-overflow-127.wasm"

wasm-validate --enable-memory64 "$control" \
  > "$out_dir/wabt-valid.log" 2>&1
set +e
wasm-validate --enable-memory64 "$overflow2" \
  > "$out_dir/wabt-overflow-2.log" 2>&1
wabt_overflow2_rc=$?
wasm-validate --enable-memory64 "$overflow127" \
  > "$out_dir/wabt-overflow-127.log" 2>&1
wabt_overflow127_rc=$?
set -e
test "$wabt_overflow2_rc" -ne 0
test "$wabt_overflow127_rc" -ne 0

cmake_common=(
  -DWAMR_BUILD_MEMORY64=1
  -DWAMR_BUILD_AOT=0
  -DWAMR_BUILD_JIT=0
  -DWAMR_BUILD_FAST_JIT=0
  -DWAMR_BUILD_SIMD=0
  -DWAMR_BUILD_LIBC_WASI=0
  -DCMAKE_BUILD_TYPE=Release
)

cmake -S "$wamr_dir/product-mini/platforms/linux" \
  -B "$out_dir/wamr-current-build" "${cmake_common[@]}" \
  > "$out_dir/wamr-current-cmake.log" 2>&1
cmake --build "$out_dir/wamr-current-build" --parallel 2 \
  > "$out_dir/wamr-current-build.log" 2>&1
current_iwasm="$out_dir/wamr-current-build/iwasm"

current_control_rc=$(run_iwasm "$current_iwasm" "$control" \
  "$out_dir/wamr-current-valid.log")
current_overflow2_rc=$(run_iwasm "$current_iwasm" "$overflow2" \
  "$out_dir/wamr-current-overflow-2.log")
current_overflow127_rc=$(run_iwasm "$current_iwasm" "$overflow127" \
  "$out_dir/wamr-current-overflow-127.log")

# Rebuild the same pinned WAMR tree with only the missing u64 overflow check.
apply_u64_fix "$wamr_dir/core/shared/utils/bh_leb128.c"
cmake -S "$wamr_dir/product-mini/platforms/linux" \
  -B "$out_dir/wamr-fixed-build" "${cmake_common[@]}" \
  > "$out_dir/wamr-fixed-cmake.log" 2>&1
cmake --build "$out_dir/wamr-fixed-build" --parallel 2 \
  > "$out_dir/wamr-fixed-build.log" 2>&1
fixed_iwasm="$out_dir/wamr-fixed-build/iwasm"

fixed_control_rc=$(run_iwasm "$fixed_iwasm" "$control" \
  "$out_dir/wamr-fixed-valid.log")
fixed_overflow2_rc=$(run_iwasm "$fixed_iwasm" "$overflow2" \
  "$out_dir/wamr-fixed-overflow-2.log")
fixed_overflow127_rc=$(run_iwasm "$fixed_iwasm" "$overflow127" \
  "$out_dir/wamr-fixed-overflow-127.log")

{
  echo 'WAMR production u64 LEB model-checking result'
  echo '================================================'
  echo "spec2maude_commit=$(git rev-parse HEAD)"
  echo "wamr_commit=$actual_wamr_sha"
  echo "maude=$($maude_bin --version 2>&1 | head -n 1 || true)"
  echo "clang=$(clang --version | head -n 1)"
  echo "wabt=$(wasm-validate --version 2>&1 | head -n 1)"
  echo
  echo '[Exact production decoder, native exhaustive check]'
  cat "$out_dir/current-native.log"
  echo
  echo '[One-line repaired decoder, native exhaustive check]'
  cat "$out_dir/fixed-native.log"
  echo
  echo '[Spec2Maude concrete execution]'
  echo 'current final payload 2 status: SUCCESS (0)'
  echo 'fixed final payload 2 status: OVERFLOW (2)'
  echo
  echo '[Spec2Maude bounded model checking: terminal payload 0..127]'
  grep -E '^(Solution 1|No solution\.|states:|rewrites:|result (Bool|ModelCheckResult):)' \
    "$out_dir/current-modelcheck.log" "$out_dir/fixed-modelcheck.log" || true
  echo
  echo '[Conforming WABT validator]'
  echo "valid_zero_rc=0"
  echo "overflow_2_rc=$wabt_overflow2_rc"
  echo "overflow_127_rc=$wabt_overflow127_rc"
  echo
  echo '[Pinned production WAMR memory64 loader]'
  echo "current_valid_zero_rc=$current_control_rc"
  echo "current_overflow_2_rc=$current_overflow2_rc"
  echo "current_overflow_127_rc=$current_overflow127_rc"
  echo "fixed_valid_zero_rc=$fixed_control_rc"
  echo "fixed_overflow_2_rc=$fixed_overflow2_rc"
  echo "fixed_overflow_127_rc=$fixed_overflow127_rc"
} | tee "$out_dir/results.txt"

# These are the expected semantic distinctions.  Keep the assertions after the
# evidence file is written so an unexpected CLI behavior remains inspectable.
test "$current_control_rc" -eq 0
test "$current_overflow2_rc" -eq 0
test "$current_overflow127_rc" -eq 0
test "$fixed_control_rc" -eq 0
test "$fixed_overflow2_rc" -ne 0
test "$fixed_overflow127_rc" -ne 0

if grep -Eq '^(Warning|Advisory|Error):' \
    "$out_dir/current-typecheck.log" "$out_dir/fixed-typecheck.log" \
    "$out_dir/current-last2.log" "$out_dir/fixed-last2.log" \
    "$out_dir/current-modelcheck.log" "$out_dir/fixed-modelcheck.log"; then
  grep -En '^(Warning|Advisory|Error):' "$out_dir"/*.log >&2 || true
  exit 1
fi

echo "Artifacts written to $out_dir"
