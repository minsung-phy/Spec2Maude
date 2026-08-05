#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
bench="$root/benchmarks/tract-relaxed-dot"
out=${1:-"${TMPDIR:-/tmp}/spec2maude-tract-relaxed-dot"}
mkdir -p "$out"
cd "$root"

maude=${MAUDE:-maude}
tract_sha=${TRACT_SHA:-a469e802d38ab2f21391b5681b62c2dbd6033211}
tract="$out/tract"

# Pin and audit the actual production source under test.
git clone --quiet https://github.com/sonos/tract.git "$tract"
git -C "$tract" checkout --quiet "$tract_sha"
test "$(git -C "$tract" rev-parse HEAD)" = "$tract_sha"
tract_kernel="$tract/linalg/src/wasm/mmm_i32.rs"
tract_pack="$tract/linalg/src/frame/pack.rs"
grep -q 'i32x4_relaxed_dot_i8x16_i7x16_add' "$tract_kernel"
grep -q 'i32x4_splat(a4)' "$tract_kernel"
grep -q 'b_all' "$tract_kernel"
grep -q 'packing\[1\] = i8i8' "$tract_kernel"
grep -q 'WeightType::Plain(i8::datum_type())' "$tract_pack"
grep -q 'out\[(k/4)\*r\*4 + m\*4 + (k%4)\] = src\[m,k\]' "$tract_pack"
sha256sum "$tract_kernel" "$tract_pack" > "$out/tract-source.sha256"
git -C "$tract" show -s --format=fuller HEAD > "$out/tract-commit.txt"
git -C "$tract" show -s --format=fuller 774d8bdba1f21c9c44a969b5d3964c7eda31aa61 \
  > "$out/tract-relaxed-dot-introduction.txt"

# Compile the instruction-level extraction of tract's production hot loop.
clang --target=wasm32-unknown-unknown -O2 -nostdlib \
  -msimd128 -mrelaxed-simd \
  "$bench/tract_kernel.c" \
  -Wl,--no-entry \
  -Wl,--export=tract_dot_lane0 \
  -Wl,--export=tract_mismatch \
  -Wl,--export=fixed_mismatch \
  -Wl,--export-memory \
  -o "$out/tract-relaxed-dot.wasm"
wasm-objdump -d "$out/tract-relaxed-dot.wasm" > "$out/tract-relaxed-dot.objdump"
# WABT 1.0.34 prints the relaxed opcode using its legacy mnemonic without the
# word "relaxed"; opcode fd 93 02 is the proposal instruction emitted by Clang.
grep -Eq 'i32x4\.(relaxed_)?dot_i8x16_i7x16_add_s' "$out/tract-relaxed-dot.objdump"
grep -q 'fd 93 02' "$out/tract-relaxed-dot.objdump"

# Produce both globally consistent profiles allowed by the official SpecTec
# semantics for R_idot.
python3 "$bench/make_profile.py" builtins.maude "$out/builtins-r-idot-0.maude" --r-idot 0
python3 "$bench/make_profile.py" builtins.maude "$out/builtins-r-idot-1.maude" --r-idot 1

for p in 0 1; do
  profile="$out/builtins-r-idot-${p}.maude"
  "$maude" -no-banner "$profile" > "$out/profile-${p}-load.log" 2>&1
  ! grep -Eq '^(Warning|Advisory|Error):' "$out/profile-${p}-load.log"

  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- module \
    "$out/tract-relaxed-dot.wasm" --semantics "$profile" \
    -o "$out/profile-${p}-typecheck.maude"
  "$maude" -no-banner "$out/profile-${p}-typecheck.maude" \
    > "$out/profile-${p}-typecheck.log" 2>&1
  grep -q 'result Bool: true' "$out/profile-${p}-typecheck.log"

  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- run \
    "$out/tract-relaxed-dot.wasm" --invoke tract_mismatch \
    --arg i32:255 --steps 500000 --semantics "$profile" \
    -o "$out/profile-${p}-b255.maude"
  "$maude" -no-banner "$out/profile-${p}-b255.maude" \
    > "$out/profile-${p}-b255.log" 2>&1

  expected=$p
  python3 "$bench/check_i32_result.py" "$out/profile-${p}-b255.log" "$expected"

  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- run \
    "$out/tract-relaxed-dot.wasm" --invoke tract_mismatch \
    --arg i32:0 --steps 500000 --semantics "$profile" \
    -o "$out/profile-${p}-base.maude"
  python3 "$bench/make_modelcheck.py" "$out/profile-${p}-base.maude" \
    "$out/profile-${p}-modelcheck.maude" \
    --module-name "TRACT-RIDOT-${p}-MC"
  "$maude" -no-banner "$out/profile-${p}-modelcheck.maude" \
    > "$out/profile-${p}-modelcheck.log" 2>&1
done

# The deterministic widening repair is independent of R_idot.  Check it under
# the hostile profile over the same complete byte space.
opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- run \
  "$out/tract-relaxed-dot.wasm" --invoke fixed_mismatch \
  --arg i32:0 --steps 500000 --semantics "$out/builtins-r-idot-1.maude" \
  -o "$out/fixed-base.maude"
python3 "$bench/make_modelcheck.py" "$out/fixed-base.maude" \
  "$out/fixed-modelcheck.maude" --module-name "TRACT-FIXED-MC"
"$maude" -no-banner "$out/fixed-modelcheck.maude" \
  > "$out/fixed-modelcheck.log" 2>&1

# Expected semantic result.
grep -q '^No solution\.' "$out/profile-0-modelcheck.log"
grep -q 'result Bool: true' "$out/profile-0-modelcheck.log"
grep -q '^Solution 1' "$out/profile-1-modelcheck.log"
grep -q 'result ModelCheckResult: counterexample' "$out/profile-1-modelcheck.log"
grep -q '^No solution\.' "$out/fixed-modelcheck.log"
grep -q 'result Bool: true' "$out/fixed-modelcheck.log"

# Concrete replay in the installed V8/Node engine.  Some Node releases expose
# the proposal flag and newer ones enable the feature without it.
set +e
node --experimental-wasm-relaxed-simd -e '0' >/dev/null 2>&1
flag_rc=$?
set -e
if test "$flag_rc" -eq 0; then
  node --experimental-wasm-relaxed-simd "$bench/run_node.mjs" \
    "$out/tract-relaxed-dot.wasm" > "$out/node.log" 2>&1
else
  node "$bench/run_node.mjs" "$out/tract-relaxed-dot.wasm" \
    > "$out/node.log" 2>&1
fi

{
  echo 'tract Relaxed-SIMD portability model-checking result'
  echo '====================================================='
  echo "spec2maude_commit=$(git rev-parse HEAD)"
  echo "tract_commit=$tract_sha"
  echo "clang=$(clang --version | head -n 1)"
  echo "node=$(node --version)"
  echo "maude=$($maude --version 2>&1 | head -n 1 || true)"
  echo
  echo '[Concrete Spec2Maude executions for byte 255]'
  echo 'R_idot=0 mismatch=0'
  echo 'R_idot=1 mismatch=1'
  echo
  echo '[Bounded model checking: every full-i8 byte 0..255]'
  for name in profile-0 profile-1 fixed; do
    echo "--- $name"
    grep -E '^(Solution 1|No solution\.|states:|rewrites:|result (Bool|ModelCheckResult):)' \
      "$out/${name}-modelcheck.log" || true
  done
  echo
  echo '[Concrete V8/Node replay]'
  cat "$out/node.log"
} | tee "$out/results.txt"

if grep -Eq '^(Warning|Advisory|Error):' \
    "$out"/profile-*-typecheck.log "$out"/profile-*-b255.log \
    "$out"/*-modelcheck.log; then
  grep -En '^(Warning|Advisory|Error):' "$out"/*.log >&2 || true
  exit 1
fi

echo "Artifacts written to $out"
