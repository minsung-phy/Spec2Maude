#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
bench="$root/benchmarks/tract-relaxed-dot"
out=${1:-"${TMPDIR:-/tmp}/spec2maude-tract-relaxed-dot-fast"}
mkdir -p "$out"
cd "$root"

maude=${MAUDE:-maude}
tract_sha=${TRACT_SHA:-a469e802d38ab2f21391b5681b62c2dbd6033211}
tract="$out/tract"

git clone --quiet https://github.com/sonos/tract.git "$tract"
git -C "$tract" checkout --quiet "$tract_sha"
test "$(git -C "$tract" rev-parse HEAD)" = "$tract_sha"
tract_kernel="$tract/linalg/src/wasm/mmm_i32.rs"
tract_pack="$tract/linalg/src/frame/pack.rs"
grep -q 'i32x4_relaxed_dot_i8x16_i7x16_add' "$tract_kernel"
grep -q 'i32x4_splat(a4)' "$tract_kernel"
grep -q 'packing\[1\] = i8i8' "$tract_kernel"
grep -q 'WeightType::Plain(i8::datum_type())' "$tract_pack"
sha256sum "$tract_kernel" "$tract_pack" > "$out/tract-source.sha256"
git -C "$tract" show -s --format=fuller HEAD > "$out/tract-commit.txt"
git -C "$tract" show -s --format=fuller 774d8bdba1f21c9c44a969b5d3964c7eda31aa61 \
  > "$out/tract-relaxed-dot-introduction.txt"

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
grep -q 'fd 93 02' "$out/tract-relaxed-dot.objdump"

cp output.maude "$out/output.maude"
python3 "$bench/make_profile.py" builtins.maude "$out/builtins-r-idot-0.maude" --r-idot 0
python3 "$bench/make_profile.py" builtins.maude "$out/builtins-r-idot-1.maude" --r-idot 1

run_case() {
  local name=$1 profile=$2 export_name=$3 input=$4
  local semantics="$out/builtins-r-idot-${profile}.maude"

  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- module \
    "$out/tract-relaxed-dot.wasm" --semantics "$semantics" \
    -o "$out/${name}-typecheck.maude"
  "$maude" -no-banner "$out/${name}-typecheck.maude" \
    > "$out/${name}-typecheck.log" 2>&1
  grep -q 'result Bool: true' "$out/${name}-typecheck.log"

  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- run \
    "$out/tract-relaxed-dot.wasm" --invoke "$export_name" \
    --arg "i32:${input}" --steps 500000 --semantics "$semantics" \
    -o "$out/${name}-base.maude"
  python3 "$bench/make_search.py" "$out/${name}-base.maude" \
    "$out/${name}-search.maude" --bad-result 1
  timeout 1200s "$maude" -no-banner "$out/${name}-search.maude" \
    > "$out/${name}-search.log" 2>&1
}

# 128 is the first signed i8 value whose signed and unsigned interpretations
# differ.  The official R_idot=0 profile must preserve the scalar contract;
# the equally legal R_idot=1 profile reaches mismatch=1.
run_case profile-0 0 tract_mismatch 128
run_case profile-1 1 tract_mismatch 128
run_case fixed 1 fixed_mismatch 128

grep -q '^No solution\.' "$out/profile-0-search.log"
grep -q '^Solution 1' "$out/profile-1-search.log"
grep -q '^No solution\.' "$out/fixed-search.log"

# A complete concrete replay of all 256 byte values in V8 shows the operational
# impact of the legal unsigned-second-operand profile.
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
grep -q '^mismatch_count=128$' "$out/node.log"
grep -q '^first_mismatch=128$' "$out/node.log"

{
  echo 'tract Relaxed-SIMD focused reachability result'
  echo '================================================'
  echo "spec2maude_commit=$(git rev-parse HEAD)"
  echo "tract_commit=$tract_sha"
  echo "clang=$(clang --version | head -n 1)"
  echo "node=$(node --version)"
  echo "maude=$($maude --version 2>&1 | head -n 1 || true)"
  echo
  echo '[Full Wasm program reachability at the signedness boundary byte 128]'
  for name in profile-0 profile-1 fixed; do
    echo "--- $name"
    grep -E '^(Solution 1|No solution\.|states:|rewrites:)' \
      "$out/${name}-search.log" || true
  done
  echo
  echo '[Concrete V8 replay over byte values 0..255]'
  cat "$out/node.log"
} | tee "$out/results.txt"

if grep -Eq '^(Warning|Advisory|Error):' \
    "$out"/*-typecheck.log "$out"/*-search.log; then
  grep -En '^(Warning|Advisory|Error):' "$out"/*.log >&2 || true
  exit 1
fi

echo "Artifacts written to $out"
