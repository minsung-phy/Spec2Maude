#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
bench="$root/benchmarks/facex-relaxed-dot"
common="$root/benchmarks/tract-relaxed-dot"
out=${1:-"${TMPDIR:-/tmp}/spec2maude-facex-relaxed-dot"}
mkdir -p "$out"
cd "$root"

maude=${MAUDE:-maude}
facex_sha=${FACEX_SHA:-af7ca9937705a10901ca4b72c4eb19ef49a4ac53}
facex="$out/facex"

git clone --quiet https://github.com/facex-engine/facex.git "$facex"
git -C "$facex" checkout --quiet "$facex_sha"
test "$(git -C "$facex" rev-parse HEAD)" = "$facex_sha"
prod="$facex/wasm/src/gemm_int8_rsimd.c"

grep -q 'C_i32\[M,N\] = A_s8\[M,K\] @ B_s8\[N,K\]' "$prod"
grep -q 'relaxed dot treats first arg as unsigned, second as signed' "$prod"
grep -q 'wasm_i32x4_relaxed_dot_i8x16_i7x16_add(va_u8, vb, acc)' "$prod"
grep -q 'sum -= 128 \* col_sums\[n\]' "$prod"
sha256sum "$prod" > "$out/facex-production-source.sha256"
git -C "$facex" show -s --format=fuller HEAD > "$out/facex-commit.txt"

# The repository's checked-in detector binary may lag the current source.
# Record its instruction coverage, but analyze the pinned current source below.
wasm-objdump -d "$facex/wasm/detect.wasm" > "$out/detect.objdump"
if grep -q 'fd 93 02' "$out/detect.objdump"; then
  echo present > "$out/shipped-relaxed-dot.txt"
else
  echo absent > "$out/shipped-relaxed-dot.txt"
fi

# Compile the exact arithmetic slice used by the current production hot loop.
clang --target=wasm32-unknown-unknown -O2 -nostdlib \
  -msimd128 -mrelaxed-simd "$bench/facex_kernel.c" \
  -Wl,--no-entry \
  -Wl,--export=facex_current_result \
  -Wl,--export=facex_current_mismatch \
  -Wl,--export=facex_swap_mismatch \
  -Wl,--export=facex_portable_mismatch \
  -Wl,--export-memory \
  -o "$out/facex-kernel.wasm"
wasm-objdump -d "$out/facex-kernel.wasm" > "$out/facex-kernel.objdump"
grep -q 'fd 93 02' "$out/facex-kernel.objdump"

cp output.maude "$out/output.maude"
python3 "$common/make_profile.py" builtins.maude "$out/builtins-r-idot-0.maude" --r-idot 0
python3 "$common/make_profile.py" builtins.maude "$out/builtins-r-idot-1.maude" --r-idot 1

run_case() {
  local name=$1 profile=$2 export_name=$3 expected=$4
  local semantics="$out/builtins-r-idot-${profile}.maude"
  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- module \
    "$out/facex-kernel.wasm" --semantics "$semantics" \
    -o "$out/${name}-typecheck.maude"
  "$maude" -no-banner "$out/${name}-typecheck.maude" > "$out/${name}-typecheck.log" 2>&1
  grep -q 'result Bool: true' "$out/${name}-typecheck.log"

  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- run \
    "$out/facex-kernel.wasm" --invoke "$export_name" \
    --arg i32:0 --steps 500000 --semantics "$semantics" \
    -o "$out/${name}-run.maude"
  "$maude" -no-banner "$out/${name}-run.maude" > "$out/${name}-run.log" 2>&1
  python3 "$common/check_i32_result.py" "$out/${name}-run.log" "$expected"
}

run_case current-r0 0 facex_current_mismatch 1
run_case current-r1 1 facex_current_mismatch 1
run_case swap-r0 0 facex_swap_mismatch 1
run_case swap-r1 1 facex_swap_mismatch 0
run_case portable-r0 0 facex_portable_mismatch 0
run_case portable-r1 1 facex_portable_mismatch 0

python3 "$common/make_search.py" "$out/current-r0-run.maude" \
  "$out/current-r0-search.maude" --bad-result 1
"$maude" -no-banner "$out/current-r0-search.maude" > "$out/current-r0-search.log" 2>&1
grep -q '^Solution 1' "$out/current-r0-search.log"

python3 "$common/make_search.py" "$out/swap-r0-run.maude" \
  "$out/swap-r0-search.maude" --bad-result 1
"$maude" -no-banner "$out/swap-r0-search.maude" > "$out/swap-r0-search.log" 2>&1
grep -q '^Solution 1' "$out/swap-r0-search.log"

node "$bench/run_node.mjs" "$out/facex-kernel.wasm" > "$out/node.log" 2>&1

{
  echo 'FaceX current-source Relaxed-SIMD correctness result'
  echo '===================================================='
  echo "spec2maude_commit=$(git rev-parse HEAD)"
  echo "facex_commit=$facex_sha"
  echo "checked_in_detect_dot=$(cat "$out/shipped-relaxed-dot.txt")"
  echo
  echo '[Spec2Maude executions at A=0, B=1, K=16]'
  echo 'current R_idot=0 mismatch=1'
  echo 'current R_idot=1 mismatch=1'
  echo 'swap-only R_idot=0 mismatch=1'
  echo 'swap-only R_idot=1 mismatch=0'
  echo 'portable R_idot=0 mismatch=0'
  echo 'portable R_idot=1 mismatch=0'
  echo
  echo '[Maude counterexample statistics]'
  grep -E '^(Solution 1|states:|rewrites:)' "$out/current-r0-search.log" || true
  grep -E '^(Solution 1|states:|rewrites:)' "$out/swap-r0-search.log" || true
  echo
  echo '[V8 replay]'
  cat "$out/node.log"
} | tee "$out/results.txt"

if grep -Eq '^(Warning|Advisory|Error):' "$out"/*-typecheck.log "$out"/*-run.log "$out"/*-search.log; then
  grep -En '^(Warning|Advisory|Error):' "$out"/*.log >&2 || true
  exit 1
fi
