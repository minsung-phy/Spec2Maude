#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
bench="$root/benchmarks/wamr-u64-leb"
out=${1:-"${TMPDIR:-/tmp}/spec2maude-wamr-u64-leb"}
mkdir -p "$out"
cd "$root"

maude=${MAUDE:-maude}
wamr_sha=${WAMR_SHA:-70f4cd383f1a474d6759e3185b4eca6f6ddde4d4}
wamr="$out/wasm-micro-runtime"

git clone --quiet https://github.com/wasm-micro-runtime/wasm-micro-runtime.git "$wamr"
git -C "$wamr" checkout --quiet "$wamr_sha"
test "$(git -C "$wamr" rev-parse HEAD)" = "$wamr_sha"

apply_fix() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')
old = '''    if (!sign && maxbits == 32 && shift >= maxbits) {
        /* The top bits set represent values > 32 bits */
        if (((uint8)byte) & 0xf0)
            return BH_LEB_READ_OVERFLOW;
    }
    else if (sign && maxbits == 32) {
'''
new = '''    if (!sign && maxbits == 32 && shift >= maxbits) {
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
'''
if s.count(old) != 1:
    raise SystemExit('expected unsigned-32 overflow block not found')
p.write_text(s.replace(old, new, 1), encoding='utf-8')
PY
}

current_src="$out/current-src"
fixed_src="$out/fixed-src"
mkdir -p "$current_src" "$fixed_src"
cp "$wamr/core/shared/utils/bh_leb128.c" \
   "$wamr/core/shared/utils/bh_leb128.h" "$current_src/"
cp "$current_src"/* "$fixed_src/"
apply_fix "$fixed_src/bh_leb128.c"
diff -u "$current_src/bh_leb128.c" "$fixed_src/bh_leb128.c" \
  > "$out/u64-overflow-fix.patch" || true

# Exhaustive native check of all terminal payloads of a ten-byte u64 LEB.
for mode in current fixed; do
  cc -O2 -Wall -Wextra -Werror -DWAMR_LEB_NATIVE_MAIN \
    -I "$out/${mode}-src" "$bench/wrapper.c" -o "$out/${mode}-native"
  "$out/${mode}-native" > "$out/${mode}-native.log"
done
grep -q '^mismatch_count=126$' "$out/current-native.log"
grep -q '^status_last_2=0$' "$out/current-native.log"
grep -q '^value_last_2=0$' "$out/current-native.log"
grep -q '^mismatch_count=0$' "$out/fixed-native.log"
grep -q '^status_last_2=2$' "$out/fixed-native.log"

# Compile the exact production decoder and the one-line repair to Wasm, then
# run and model-check them with Spec2Maude's generated official semantics.
for mode in current fixed; do
  clang --target=wasm32-unknown-unknown -O2 -nostdlib \
    -I "$out/${mode}-src" "$bench/wrapper.c" \
    -Wl,--no-entry -Wl,--export=wamr_decode_status \
    -Wl,--export=wamr_decode_value -Wl,--export-memory \
    -o "$out/wamr-leb-${mode}.wasm"

  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- module \
    "$out/wamr-leb-${mode}.wasm" --semantics builtins.maude \
    -o "$out/${mode}-typecheck.maude"
  "$maude" -no-banner "$out/${mode}-typecheck.maude" \
    > "$out/${mode}-typecheck.log" 2>&1
  grep -q 'result Bool: true' "$out/${mode}-typecheck.log"

  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- run \
    "$out/wamr-leb-${mode}.wasm" --invoke wamr_decode_status \
    --arg i32:2 --steps 500000 --semantics builtins.maude \
    -o "$out/${mode}-last2.maude"
  "$maude" -no-banner "$out/${mode}-last2.maude" \
    > "$out/${mode}-last2.log" 2>&1

  expected=0
  test "$mode" = fixed && expected=2
  python3 "$bench/check_maude_result.py" "$out/${mode}-last2.log" "$expected"

  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- run \
    "$out/wamr-leb-${mode}.wasm" --invoke wamr_decode_status \
    --arg i32:0 --steps 500000 --semantics builtins.maude \
    -o "$out/${mode}-base.maude"
  python3 "$bench/make_modelcheck.py" "$out/${mode}-base.maude" \
    "$out/${mode}-modelcheck.maude" \
    --module-name "WAMR-LEB-${mode^^}-MC" --max-last 127
  "$maude" -no-banner "$out/${mode}-modelcheck.maude" \
    > "$out/${mode}-modelcheck.log" 2>&1
done

grep -q '^Solution 1' "$out/current-modelcheck.log"
grep -q 'result ModelCheckResult: counterexample' "$out/current-modelcheck.log"
grep -q '^No solution\.' "$out/fixed-modelcheck.log"
grep -q 'result Bool: true' "$out/fixed-modelcheck.log"

# Concrete malformed modules reach the same production decoder through a
# memory64 load's u64 memarg offset.
python3 "$bench/generate_modules.py" "$out/modules" \
  > "$out/generated-modules.log"
valid="$out/modules/memory64-offset-valid-zero.wasm"
overflow2="$out/modules/memory64-offset-overflow-2.wasm"
overflow127="$out/modules/memory64-offset-overflow-127.wasm"

wasm-validate --enable-memory64 "$valid" > "$out/wabt-valid.log" 2>&1
for pair in "2:$overflow2" "127:$overflow127"; do
  name=${pair%%:*}; file=${pair#*:}
  set +e
  wasm-validate --enable-memory64 "$file" > "$out/wabt-overflow-${name}.log" 2>&1
  rc=$?
  set -e
  test "$rc" -ne 0
  echo "$rc" > "$out/wabt-overflow-${name}.rc"
done

cmake_args=(
  -DWAMR_BUILD_MEMORY64=1
  -DWAMR_BUILD_AOT=0
  -DWAMR_BUILD_JIT=0
  -DWAMR_BUILD_FAST_JIT=0
  -DWAMR_BUILD_FAST_INTERP=0
  -DWAMR_BUILD_SIMD=0
  -DWAMR_BUILD_LIBC_WASI=0
  -DCMAKE_BUILD_TYPE=Release
)

build_runtime() {
  local mode=$1
  cmake -S "$wamr/product-mini/platforms/linux" \
    -B "$out/wamr-${mode}-build" "${cmake_args[@]}" \
    > "$out/wamr-${mode}-cmake.log" 2>&1
  cmake --build "$out/wamr-${mode}-build" --parallel 2 \
    > "$out/wamr-${mode}-build.log" 2>&1
}
run_module() {
  local exe=$1 module=$2 log=$3
  set +e
  timeout 20s "$exe" "$module" > "$log" 2>&1
  local rc=$?
  set -e
  echo "$rc"
}

build_runtime current
current_iwasm="$out/wamr-current-build/iwasm"
current_valid_rc=$(run_module "$current_iwasm" "$valid" "$out/wamr-current-valid.log")
current_2_rc=$(run_module "$current_iwasm" "$overflow2" "$out/wamr-current-overflow-2.log")
current_127_rc=$(run_module "$current_iwasm" "$overflow127" "$out/wamr-current-overflow-127.log")

apply_fix "$wamr/core/shared/utils/bh_leb128.c"
build_runtime fixed
fixed_iwasm="$out/wamr-fixed-build/iwasm"
fixed_valid_rc=$(run_module "$fixed_iwasm" "$valid" "$out/wamr-fixed-valid.log")
fixed_2_rc=$(run_module "$fixed_iwasm" "$overflow2" "$out/wamr-fixed-overflow-2.log")
fixed_127_rc=$(run_module "$fixed_iwasm" "$overflow127" "$out/wamr-fixed-overflow-127.log")

{
  echo 'WAMR production u64 LEB validation-soundness result'
  echo '===================================================='
  echo "spec2maude_commit=$(git rev-parse HEAD)"
  echo "wamr_commit=$wamr_sha"
  echo
  echo '[Exact production decoder, native exhaustive check]'
  cat "$out/current-native.log"
  echo
  echo '[One-line repair, native exhaustive check]'
  cat "$out/fixed-native.log"
  echo
  echo '[Spec2Maude bounded model checking]'
  grep -E '^(Solution 1|No solution\.|states:|rewrites:|result (Bool|ModelCheckResult):)' \
    "$out/current-modelcheck.log" "$out/fixed-modelcheck.log" || true
  echo
  echo '[WABT versus full pinned WAMR]'
  echo "wabt_overflow_2_rc=$(cat "$out/wabt-overflow-2.rc")"
  echo "wabt_overflow_127_rc=$(cat "$out/wabt-overflow-127.rc")"
  echo "current_valid_rc=$current_valid_rc"
  echo "current_overflow_2_rc=$current_2_rc"
  echo "current_overflow_127_rc=$current_127_rc"
  echo "fixed_valid_rc=$fixed_valid_rc"
  echo "fixed_overflow_2_rc=$fixed_2_rc"
  echo "fixed_overflow_127_rc=$fixed_127_rc"
} | tee "$out/results.txt"

# Current WAMR executes 2^64 as offset zero, and reaches execution for the 0x7f
# witness before trapping out of bounds.  The repair rejects both at load time.
test "$current_valid_rc" -eq 0
test "$current_2_rc" -eq 0
test "$current_127_rc" -eq 1
test "$fixed_valid_rc" -eq 0
test "$fixed_2_rc" -eq 255
test "$fixed_127_rc" -eq 255
grep -q 'out of bounds memory access' "$out/wamr-current-overflow-127.log"
grep -Eq 'offset out of range|integer too large' "$out/wamr-fixed-overflow-2.log"
grep -Eq 'offset out of range|integer too large' "$out/wamr-fixed-overflow-127.log"

echo "Artifacts written to $out"
