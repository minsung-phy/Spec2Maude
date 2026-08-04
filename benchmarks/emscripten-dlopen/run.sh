#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
out_dir=${1:-"${TMPDIR:-/tmp}/spec2maude-emscripten-dlopen"}
mkdir -p "$out_dir"

image=${EMSDK_IMAGE:-emscripten/emsdk:latest}
bench="$root/benchmarks/emscripten-dlopen"

# Keep all generated files in the artifact directory while mounting the source
# benchmark read-only.
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

    emcc /src/main.c -O0 \
      -sMAIN_MODULE=2 \
      -sASSERTIONS=0 \
      -sEXIT_RUNTIME=1 \
      -sENVIRONMENT=node \
      -sALLOW_TABLE_GROWTH=1 \
      -o /out/main.js

    cd /out
    node main.js > production.log 2>&1 || true
  '

cat "$out_dir/production.log"

# A correct failed-load cache must not turn a later dlopen into a successful
# handle without valid exports. Detect the production-build poison pattern:
# first load fails, second load reports a non-null handle, dlsym fails.
grep -q '^attempt_1_handle_nonnull=0$' "$out_dir/production.log"
grep -q '^attempt_2_handle_nonnull=1$' "$out_dir/production.log"
grep -q '^attempt_2_symbol_nonnull=0$' "$out_dir/production.log"

{
  echo 'Emscripten repeated-failed-dlopen result'
  echo '========================================='
  echo "image=$image"
  cat "$out_dir/node-version.log"
  echo
  grep '^attempt_' "$out_dir/production.log"
  echo
  echo 'Finding: failed side-module construction leaves a cached DSO in loading state.'
  echo 'The first dlopen fails, but the second returns a non-null poisoned handle.'
} | tee "$out_dir/results.txt"
