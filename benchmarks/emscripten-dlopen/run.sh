#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
out_dir=${1:-"${TMPDIR:-/tmp}/spec2maude-emscripten-dlopen"}
mkdir -p "$out_dir"

image=${EMSDK_IMAGE:-emscripten/emsdk:latest}
bench="$root/benchmarks/emscripten-dlopen"

# Compile both the current production loader and a minimal cache-cleanup
# variant in the same pinned container image.
docker run --rm \
  -v "$bench:/src:ro" \
  -v "$out_dir:/out" \
  -w /out \
  "$image" \
  bash -lc '
    set -euo pipefail
    emcc -v > /out/emcc-version.log 2>&1
    node --version > /out/node-version.log

    emcc /src/bad_side.c -O0 \
      -sSIDE_MODULE=2 \
      -Wl,--export=zombie_value \
      -o /out/libbad.wasm

    compile_main() {
      local output=$1
      emcc /src/main.c -O0 \
        -sMAIN_MODULE=2 \
        -sASSERTIONS=0 \
        -sEXIT_RUNTIME=1 \
        -sENVIRONMENT=node \
        -sALLOW_TABLE_GROWTH=1 \
        -o "$output"
    }

    compile_main /out/main-production.js
    cd /out
    node main-production.js > production.log 2>&1 || true

    python3 /src/patch_libdylink.py \
      /emsdk/upstream/emscripten/src/lib/libdylink.js \
      > /out/patch.log

    compile_main /out/main-fixed.js
    node main-fixed.js > fixed.log 2>&1 || true
  '

# Current production behavior: the first constructor trap is reported, but a
# later dlopen of the same name returns a poisoned non-null handle.
grep -q '^attempt_1_handle_nonnull=0$' "$out_dir/production.log"
grep -q '^attempt_2_handle_nonnull=1$' "$out_dir/production.log"
grep -q '^attempt_2_symbol_nonnull=0$' "$out_dir/production.log"

# The failed module's table function and captured private counter remain live.
for log in production fixed; do
  grep -q '^attempt_1_residual_slot_callable=1$' "$out_dir/${log}.log"
  grep -q '^attempt_1_residual_result_1=41$' "$out_dir/${log}.log"
  grep -q '^attempt_1_residual_result_2=42$' "$out_dir/${log}.log"
done

# Minimal remediation: evict the `loading` DSO on rejection. Both calls now
# execute a real load attempt and both correctly report failure. This fixes
# the API/cache inconsistency, but not the residual table capability.
grep -q '^attempt_1_handle_nonnull=0$' "$out_dir/fixed.log"
grep -q '^attempt_2_handle_nonnull=0$' "$out_dir/fixed.log"

{
  echo 'Emscripten failed-dlopen lifecycle result'
  echo '========================================='
  echo "image=$image"
  cat "$out_dir/node-version.log"
  echo
  echo '[Current production loader]'
  grep '^attempt_' "$out_dir/production.log"
  echo
  echo '[Minimal cache-cleanup patch]'
  grep '^attempt_' "$out_dir/fixed.log"
  echo
  echo '[Finding 1] stale loading DSO / poisoned dlopen handle'
  echo 'The first dlopen fails, but the second returns a non-null handle with no exports.'
  echo 'Evicting the failed DSO prevents the false-success handle.'
  echo
  echo '[Finding 2] stateful residual capability after failed construction'
  echo 'The failed side module grows the shared table and leaves callable code behind.'
  echo 'That code retains private mutable state and returns 41, then 42 after dlopen returned NULL.'
  echo 'Cache eviction alone does not revoke the residual table capability.'
} | tee "$out_dir/results.txt"
