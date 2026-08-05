#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
bench="$root/benchmarks/bitnet-relaxed-dot"
common="$root/benchmarks/tract-relaxed-dot"
out=${1:-"${TMPDIR:-/tmp}/spec2maude-bitnet-relaxed-dot"}
mkdir -p "$out"
cd "$root"

maude=${MAUDE:-maude}
bitnet_sha=${BITNET_SHA:-bfd5877d44a28c152c2fbee8e134b423e3bfe0e7}
bitnet="$out/bitnet.c"

git clone --quiet https://github.com/artalis-io/bitnet.c.git "$bitnet"
git -C "$bitnet" checkout --quiet "$bitnet_sha"
test "$(git -C "$bitnet" rev-parse HEAD)" = "$bitnet_sha"
wasm_logits="$bitnet/src/transformer/logits_wasm.c"
scalar_logits="$bitnet/src/transformer/logits_scalar.c"
cpu_backend="$bitnet/src/transformer/cpu_backend.c"

# Audit the exact production contract: signed int8 embedding weights and
# signed int8 quantized activations are passed in that order to the relaxed
# dot, while the scalar implementation multiplies both as signed int8.
# Quantization emits negative values, so the disputed domain is reachable.
grep -q 'const int8_t \*row = emb_i8' "$wasm_logits"
grep -q 'const int8_t \*quantized = lc->quantized' "$wasm_logits"
grep -q 'wasm_i32x4_relaxed_dot_i8x16_i7x16_add(wasm_v128_load(row+d),[[:space:]]*wasm_v128_load(quantized+d),[[:space:]]*acc0)' "$wasm_logits"
grep -q 'const int8_t \*row' "$scalar_logits"
grep -q 'const int8_t \*quantized' "$scalar_logits"
grep -q 'total += (int32_t)row\[d\] \* (int32_t)quantized\[d\]' "$scalar_logits"
grep -q 'if (q < -127)' "$cpu_backend"
sha256sum "$wasm_logits" "$scalar_logits" "$cpu_backend" \
  > "$out/bitnet-source.sha256"
git -C "$bitnet" show -s --format=fuller HEAD > "$out/bitnet-commit.txt"

clang --target=wasm32-unknown-unknown -O2 -nostdlib \
  -msimd128 -mrelaxed-simd \
  "$bench/bitnet_kernel.c" \
  -Wl,--no-entry \
  -Wl,--export=bitnet_dot_lane0 \
  -Wl,--export=bitnet_mismatch \
  -Wl,--export=fixed_mismatch \
  -Wl,--export-memory \
  -o "$out/bitnet-relaxed-dot.wasm"
wasm-objdump -d "$out/bitnet-relaxed-dot.wasm" > "$out/bitnet-relaxed-dot.objdump"
grep -q 'fd 93 02' "$out/bitnet-relaxed-dot.objdump"

cp output.maude "$out/output.maude"
python3 "$common/make_profile.py" builtins.maude \
  "$out/builtins-r-idot-0.maude" --r-idot 0
python3 "$common/make_profile.py" builtins.maude \
  "$out/builtins-r-idot-1.maude" --r-idot 1

run_concrete() {
  local name=$1 profile=$2 export_name=$3 input=$4 expected=$5
  local semantics="$out/builtins-r-idot-${profile}.maude"

  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- module \
    "$out/bitnet-relaxed-dot.wasm" --semantics "$semantics" \
    -o "$out/${name}-typecheck.maude"
  "$maude" -no-banner "$out/${name}-typecheck.maude" \
    > "$out/${name}-typecheck.log" 2>&1
  grep -q 'result Bool: true' "$out/${name}-typecheck.log"

  opam exec -- dune exec --profile release ./bin/wasm2maude.exe -- run \
    "$out/bitnet-relaxed-dot.wasm" --invoke "$export_name" \
    --arg "i32:${input}" --steps 500000 --semantics "$semantics" \
    -o "$out/${name}-run.maude"
  "$maude" -no-banner "$out/${name}-run.maude" \
    > "$out/${name}-run.log" 2>&1
  python3 "$common/check_i32_result.py" "$out/${name}-run.log" "$expected"
}

# 128 is the first negative int8 encoding.  Official profile 0 agrees with the
# scalar signed×signed logits contract; equally legal profile 1 interprets the
# activation byte as unsigned and reaches a mismatch.
run_concrete profile-0 0 bitnet_mismatch 128 0
run_concrete profile-1 1 bitnet_mismatch 128 1
run_concrete fixed 1 fixed_mismatch 128 0

python3 "$common/make_search.py" "$out/profile-1-run.maude" \
  "$out/profile-1-search.maude" --bad-result 1
timeout 1200s "$maude" -no-banner "$out/profile-1-search.maude" \
  > "$out/profile-1-search.log" 2>&1
grep -q '^Solution 1' "$out/profile-1-search.log"

set +e
node --experimental-wasm-relaxed-simd -e '0' >/dev/null 2>&1
flag_rc=$?
set -e
if test "$flag_rc" -eq 0; then
  node --experimental-wasm-relaxed-simd "$bench/run_node.mjs" \
    "$out/bitnet-relaxed-dot.wasm" > "$out/node.log" 2>&1
else
  node "$bench/run_node.mjs" "$out/bitnet-relaxed-dot.wasm" \
    > "$out/node.log" 2>&1
fi

{
  echo 'bitnet.c Relaxed-SIMD logits portability result'
  echo '================================================'
  echo "spec2maude_commit=$(git rev-parse HEAD)"
  echo "bitnet_commit=$bitnet_sha"
  echo "clang=$(clang --version | head -n 1)"
  echo "node=$(node --version)"
  echo "maude=$($maude --version 2>&1 | head -n 1 || true)"
  echo
  echo '[Full generated Wasm semantics at activation byte 128]'
  echo 'R_idot=0 mismatch=0'
  echo 'R_idot=1 mismatch=1'
  echo 'deterministic repair under R_idot=1 mismatch=0'
  echo
  echo '[Maude reachability counterexample under legal R_idot=1]'
  grep -E '^(Solution 1|states:|rewrites:)' "$out/profile-1-search.log" || true
  echo
  echo '[Concrete V8 replay over activation bytes 0..255]'
  cat "$out/node.log"
} | tee "$out/results.txt"

# Do not assume V8's legal global R_idot choice here; the authoritative bug
# claim is the full-profile Spec2Maude counterexample.  Preserve concrete V8
# behaviour as empirical evidence, whatever legal profile it implements.
if grep -Eq '^(Warning|Advisory|Error):' \
    "$out"/*-typecheck.log "$out"/*-run.log "$out/profile-1-search.log"; then
  grep -En '^(Warning|Advisory|Error):' "$out"/*.log >&2 || true
  exit 1
fi

echo "Artifacts written to $out"
