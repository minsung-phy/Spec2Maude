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

# The checked-in detector binary may lag the current source. Record its opcode
# coverage, but analyze the pinned current source below.
wasm-objdump -d "$facex/wasm/detect.wasm" > "$out/detect.objdump"
if grep -q 'fd 93 02' "$out/detect.objdump"; then
  echo present > "$out/shipped-relaxed-dot.txt"
else
  echo absent > "$out/shipped-relaxed-dot.txt"
fi

# Compile a small source-faithful arithmetic slice for repair comparison.
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

# Compile the exact production function body together with a no-argument
# witness wrapper. Only unavailable libc include lines are removed; the pinned
# FaceX function bodies are byte-for-byte unchanged and their hash is recorded.
grep -v '^#include <stdlib.h>' "$prod" | grep -v '^#include <string.h>' \
  > "$out/gemm_int8_rsimd_exact.c"
cat > "$out/libc_support.c" <<'C'
#include <stddef.h>
void *memset(void *p, int c, size_t n) {
  unsigned char *q = (unsigned char *)p;
  for (size_t i = 0; i < n; ++i) q[i] = (unsigned char)c;
  return p;
}
C
clang --target=wasm32-unknown-unknown -O2 -nostdlib \
  -msimd128 -mrelaxed-simd -ffunction-sections \
  "$out/gemm_int8_rsimd_exact.c" "$bench/facex_exact_wrapper.c" "$out/libc_support.c" \
  -Wl,--no-entry -Wl,--gc-sections \
  -Wl,--export=facex_exact_mismatch \
  -Wl,--export=facex_exact_result \
  -Wl,--export-memory \
  -o "$out/facex-exact.wasm"
wasm-objdump -d "$out/facex-exact.wasm" > "$out/facex-exact.objdump"
grep -q 'fd 93 02' "$out/facex-exact.objdump"

cp output.maude "$out/output.maude"
python3 "$common/make_profile.py" builtins.maude "$out/builtins-r-idot-0.maude" --r-idot 0
python3 "$common/make_profile.py" builtins.maude "$out/builtins-r-idot-1.maude" --r-idot 1

run_arg_case() {
  local module=$1 name=$2 profile=$3 export_name=$4 input=$5 expected=$6
  local semantics="$out/builtins-r-idot-${profile}.maude"
  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- module \
    "$module" --semantics "$semantics" -o "$out/${name}-typecheck.maude"
  "$maude" -no-banner "$out/${name}-typecheck.maude" > "$out/${name}-typecheck.log" 2>&1
  grep -q 'result Bool: true' "$out/${name}-typecheck.log"
  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- run \
    "$module" --invoke "$export_name" --arg "i32:${input}" \
    --steps 500000 --semantics "$semantics" -o "$out/${name}-run.maude"
  "$maude" -no-banner "$out/${name}-run.maude" > "$out/${name}-run.log" 2>&1
  python3 "$common/check_i32_result.py" "$out/${name}-run.log" "$expected"
}

run_noarg_case() {
  local module=$1 name=$2 profile=$3 export_name=$4 expected=$5
  local semantics="$out/builtins-r-idot-${profile}.maude"
  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- module \
    "$module" --semantics "$semantics" -o "$out/${name}-typecheck.maude"
  "$maude" -no-banner "$out/${name}-typecheck.maude" > "$out/${name}-typecheck.log" 2>&1
  grep -q 'result Bool: true' "$out/${name}-typecheck.log"
  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- run \
    "$module" --invoke "$export_name" --steps 500000 \
    --semantics "$semantics" -o "$out/${name}-run.maude"
  "$maude" -no-banner "$out/${name}-run.maude" > "$out/${name}-run.log" 2>&1
  python3 "$common/check_i32_result.py" "$out/${name}-run.log" "$expected"
}

# Concrete executions through the full generated Wasm semantics.
run_arg_case "$out/facex-kernel.wasm" current-r0 0 facex_current_mismatch 0 1
run_arg_case "$out/facex-kernel.wasm" current-r1 1 facex_current_mismatch 0 1
run_arg_case "$out/facex-kernel.wasm" swap-r0 0 facex_swap_mismatch 0 1
run_arg_case "$out/facex-kernel.wasm" swap-r1 1 facex_swap_mismatch 0 0
run_arg_case "$out/facex-kernel.wasm" portable-r0 0 facex_portable_mismatch 0 0
run_arg_case "$out/facex-kernel.wasm" portable-r1 1 facex_portable_mismatch 0 0
run_noarg_case "$out/facex-exact.wasm" exact-r0 0 facex_exact_mismatch 1
run_noarg_case "$out/facex-exact.wasm" exact-r1 1 facex_exact_mismatch 1

# Fast semantics-level model checking of the production Relaxed-SIMD step.
# This avoids exploding the deterministic module-allocation state space while
# still searches the generated SpecTec rule itself.  A=0 is transformed by
# FaceX into sixteen 0x80 bytes; B contains sixteen 1 bytes.  The official
# semantics treats operand 1 as signed, yielding four lanes of -512.
ALL80=170808403787765189503184116671632670848
ALL01=1334440654591915542993625911497130241
NEG512=340282326435347409248011873270500425216
POS512=40564819216748073815832816255488
for p in 0 1; do
  cat > "$out/direct-current-r${p}.maude" <<EOF
load $out/builtins-r-idot-${p}.maude
search [1] in WASM-BUILTINS :
  def.vextternop(
    ishape.wrap(shape.x(packtype.i8, dim.wrap(16))),
    ishape.wrap(shape.x(numtype.i32, dim.wrap(4))),
    vextternop.relaxed-dot-add-s,
    uN.wrap($ALL80), uN.wrap($ALL01), uN.wrap(0))
  =>* uN.wrap($NEG512) .
quit
EOF
  "$maude" -no-banner "$out/direct-current-r${p}.maude" \
    > "$out/direct-current-r${p}.log" 2>&1
  grep -q '^Solution 1' "$out/direct-current-r${p}.log"
done

# Model-check the tempting operand-swap repair across both legal profiles.
cat > "$out/direct-swap-r0.maude" <<EOF
load $out/builtins-r-idot-0.maude
search [1] in WASM-BUILTINS :
  def.vextternop(
    ishape.wrap(shape.x(packtype.i8, dim.wrap(16))),
    ishape.wrap(shape.x(numtype.i32, dim.wrap(4))),
    vextternop.relaxed-dot-add-s,
    uN.wrap($ALL01), uN.wrap($ALL80), uN.wrap(0))
  =>* uN.wrap($NEG512) .
quit
EOF
cat > "$out/direct-swap-r1.maude" <<EOF
load $out/builtins-r-idot-1.maude
search [1] in WASM-BUILTINS :
  def.vextternop(
    ishape.wrap(shape.x(packtype.i8, dim.wrap(16))),
    ishape.wrap(shape.x(numtype.i32, dim.wrap(4))),
    vextternop.relaxed-dot-add-s,
    uN.wrap($ALL01), uN.wrap($ALL80), uN.wrap(0))
  =>* uN.wrap($POS512) .
quit
EOF
for p in 0 1; do
  "$maude" -no-banner "$out/direct-swap-r${p}.maude" \
    > "$out/direct-swap-r${p}.log" 2>&1
  grep -q '^Solution 1' "$out/direct-swap-r${p}.log"
done

node "$bench/run_node.mjs" "$out/facex-kernel.wasm" > "$out/node.log" 2>&1

{
  echo 'FaceX current-source Relaxed-SIMD correctness result'
  echo '===================================================='
  echo "spec2maude_commit=$(git rev-parse HEAD)"
  echo "facex_commit=$facex_sha"
  echo "checked_in_detect_dot=$(cat "$out/shipped-relaxed-dot.txt")"
  echo
  echo '[Exact production function via wasm2maude/output.maude/builtins.maude]'
  echo 'exact R_idot=0 mismatch=1'
  echo 'exact R_idot=1 mismatch=1'
  echo
  echo '[Repair comparison through full generated Wasm semantics]'
  echo 'current R_idot=0 mismatch=1'
  echo 'current R_idot=1 mismatch=1'
  echo 'swap-only R_idot=0 mismatch=1'
  echo 'swap-only R_idot=1 mismatch=0'
  echo 'portable R_idot=0 mismatch=0'
  echo 'portable R_idot=1 mismatch=0'
  echo
  echo '[Generated-SpecTec rule search]'
  for f in direct-current-r0 direct-current-r1 direct-swap-r0 direct-swap-r1; do
    echo "--- $f"
    grep -E '^(Solution 1|states:|rewrites:)' "$out/$f.log" || true
  done
  echo
  echo '[V8 replay]'
  cat "$out/node.log"
} | tee "$out/results.txt"

if grep -Eq '^(Warning|Advisory|Error):' \
    "$out"/*-typecheck.log "$out"/*-run.log "$out"/direct-*.log; then
  grep -En '^(Warning|Advisory|Error):' "$out"/*.log >&2 || true
  exit 1
fi
