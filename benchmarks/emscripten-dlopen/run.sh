#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
out_dir=${1:-"${TMPDIR:-/tmp}/spec2maude-emscripten-dlopen"}
mkdir -p "$out_dir"

image=${EMSDK_IMAGE:-emscripten/emsdk:latest}
bench="$root/benchmarks/emscripten-dlopen"

# Compile the production-loader experiments and a minimal failed-DSO cache
# cleanup variant in the same Emscripten container image.
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

    emcc /src/good_side.c -O0 \
      -sSIDE_MODULE=2 \
      -Wl,--export=zombie_value \
      -o /out/libgood.wasm

    emcc /src/consumer_side.c -O0 \
      -sSIDE_MODULE=2 \
      -Wl,--export=consumer_value \
      -o /out/libconsumer.wasm
    cp /out/libconsumer.wasm /out/libconsumer-pre.wasm
    cp /out/libconsumer.wasm /out/libconsumer-post.wasm

    emcc /src/local_provider.c -O0 \
      -sSIDE_MODULE=2 \
      -Wl,--export=local_only \
      -o /out/liblocal-provider.wasm

    emcc /src/local_consumer.c -O0 \
      -sSIDE_MODULE=2 \
      -Wl,--export=call_local \
      -o /out/liblocal-consumer.wasm

    compile_main() {
      local source=$1
      local output=$2
      shift 2
      emcc "/src/$source" -O0 \
        -sMAIN_MODULE=2 \
        -sASSERTIONS=0 \
        -sEXIT_RUNTIME=1 \
        -sENVIRONMENT=node \
        -sALLOW_TABLE_GROWTH=1 \
        "$@" \
        -o "$output"
    }

    compile_main main.c /out/main-production.js
    compile_main symbol_poison_main.c /out/symbol-production.js
    compile_main local_scope_main.c /out/local-scope.js -DLOAD_GLOBAL=0
    compile_main local_scope_main.c /out/global-scope.js -DLOAD_GLOBAL=1

    cd /out
    node main-production.js > production.log 2>&1 || true
    node symbol-production.js > symbol-production.log 2>&1 || true
    node local-scope.js > emscripten-local-scope.log 2>&1 || true
    node global-scope.js > emscripten-global-scope.log 2>&1 || true

    python3 /src/patch_libdylink.py \
      /emsdk/upstream/emscripten/src/lib/libdylink.js \
      > /out/patch.log

    compile_main main.c /out/main-fixed.js
    compile_main symbol_poison_main.c /out/symbol-fixed.js
    node main-fixed.js > fixed.log 2>&1 || true
    node symbol-fixed.js > symbol-fixed.log 2>&1 || true
  '

# Native Linux is the semantic control for RTLD_LOCAL/RTLD_GLOBAL and
# RTLD_NOW unresolved-symbol handling.
(
  cd "$out_dir"
  cc -fPIC -shared "$bench/local_provider.c" -o liblocal-provider.so
  cc -fPIC -shared "$bench/local_consumer.c" -o liblocal-consumer.so
  cc "$bench/local_scope_main.c" -DLOAD_GLOBAL=0 -ldl -o native-local-scope
  cc "$bench/local_scope_main.c" -DLOAD_GLOBAL=1 -ldl -o native-global-scope
  ./native-local-scope > native-local-scope.log 2>&1 || true
  ./native-global-scope > native-global-scope.log 2>&1 || true
)

# Finding 1: a constructor trap leaves a stale `loading` DSO. With assertions
# disabled, a second dlopen returns a non-null handle with no exports.
grep -q '^attempt_1_handle_nonnull=0$' "$out_dir/production.log"
grep -q '^attempt_2_handle_nonnull=1$' "$out_dir/production.log"
grep -q '^attempt_2_symbol_nonnull=0$' "$out_dir/production.log"

# Finding 2: the failed side module has already grown the shared table and its
# stateful function remains callable after dlopen returned NULL.
for log in production fixed; do
  grep -q '^attempt_1_residual_slot_callable=1$' "$out_dir/${log}.log"
  grep -q '^attempt_1_residual_result_1=41$' "$out_dir/${log}.log"
  grep -q '^attempt_1_residual_result_2=42$' "$out_dir/${log}.log"
done

# Cache eviction fixes the false-success handle but cannot revoke the residual
# table capability.
grep -q '^attempt_1_handle_nonnull=0$' "$out_dir/fixed.log"
grep -q '^attempt_2_handle_nonnull=0$' "$out_dir/fixed.log"

# Finding 3: RTLD_NOW is accepted for a consumer whose required symbol is not
# available. dlopen and dlsym both report success; the first call escapes the
# Wasm boundary as a JavaScript TypeError. Failed-DSO cache cleanup does not
# affect this independent behavior.
for log in symbol-production symbol-fixed; do
  grep -q '^bad_handle_nonnull=0$' "$out_dir/${log}.log"
  grep -q '^pre_consumer_handle_nonnull=1$' "$out_dir/${log}.log"
  grep -q '^pre_consumer_open_error=<none>$' "$out_dir/${log}.log"
  grep -q '^pre_consumer_symbol_nonnull=1$' "$out_dir/${log}.log"
  grep -q '^pre_consumer_symbol_error=<none>$' "$out_dir/${log}.log"
  grep -q 'TypeError: resolved is not a function' "$out_dir/${log}.log"
done

# Native RTLD_LOCAL control: direct dlsym on the provider works, but the symbol
# is absent from RTLD_DEFAULT and an unrelated RTLD_NOW consumer is rejected at
# dlopen time. RTLD_GLOBAL makes both operations succeed.
grep -q '^provider_handle_nonnull=1$' "$out_dir/native-local-scope.log"
grep -q '^provider_direct_result=777$' "$out_dir/native-local-scope.log"
grep -q '^default_symbol_nonnull=0$' "$out_dir/native-local-scope.log"
grep -q '^consumer_handle_nonnull=0$' "$out_dir/native-local-scope.log"
grep -q '^provider_handle_nonnull=1$' "$out_dir/native-global-scope.log"
grep -q '^provider_direct_result=777$' "$out_dir/native-global-scope.log"
grep -q '^default_symbol_nonnull=1$' "$out_dir/native-global-scope.log"
grep -q '^default_result=777$' "$out_dir/native-global-scope.log"
grep -q '^consumer_handle_nonnull=1$' "$out_dir/native-global-scope.log"
grep -q '^consumer_result=777$' "$out_dir/native-global-scope.log"

# Emscripten preserves RTLD_LOCAL visibility for RTLD_DEFAULT, but violates the
# RTLD_NOW failure boundary: the unrelated consumer is reported loaded and only
# crashes when its unresolved import is called.
grep -q '^provider_handle_nonnull=1$' "$out_dir/emscripten-local-scope.log"
grep -q '^provider_direct_result=777$' "$out_dir/emscripten-local-scope.log"
grep -q '^default_symbol_nonnull=0$' "$out_dir/emscripten-local-scope.log"
grep -q '^consumer_handle_nonnull=1$' "$out_dir/emscripten-local-scope.log"
grep -q '^consumer_open_error=<none>$' "$out_dir/emscripten-local-scope.log"
grep -q '^consumer_symbol_nonnull=1$' "$out_dir/emscripten-local-scope.log"
grep -q 'TypeError: resolved is not a function' "$out_dir/emscripten-local-scope.log"

# Emscripten RTLD_GLOBAL is the resolved-symbol control.
grep -q '^provider_handle_nonnull=1$' "$out_dir/emscripten-global-scope.log"
grep -q '^provider_direct_result=777$' "$out_dir/emscripten-global-scope.log"
grep -q '^default_symbol_nonnull=1$' "$out_dir/emscripten-global-scope.log"
grep -q '^default_result=777$' "$out_dir/emscripten-global-scope.log"
grep -q '^consumer_handle_nonnull=1$' "$out_dir/emscripten-global-scope.log"
grep -q '^consumer_result=777$' "$out_dir/emscripten-global-scope.log"

{
  echo 'Emscripten dynamic-loader model-checking targets'
  echo '================================================='
  echo "image=$image"
  cat "$out_dir/node-version.log"
  head -n 1 "$out_dir/emcc-version.log"
  echo
  echo '[Finding 1: stale failed-DSO cache]'
  grep '^attempt_' "$out_dir/production.log"
  echo
  echo '[Cache-only repair]'
  grep '^attempt_' "$out_dir/fixed.log"
  echo
  echo '[Finding 2: stateful residual Wasm capability]'
  echo 'failed_dlopen_residual_results=41,42'
  echo 'cache_cleanup_residual_results=41,42'
  echo
  echo '[Finding 3: Emscripten RTLD_NOW false success]'
  grep -E '^(provider|default|consumer)_' "$out_dir/emscripten-local-scope.log"
  grep 'TypeError: resolved is not a function' "$out_dir/emscripten-local-scope.log"
  echo 'emscripten_rtld_now=LOAD_SUCCEEDED_THEN_HOST_TYPEERROR'
  echo
  echo '[Native Linux RTLD_NOW control]'
  grep -E '^(provider|default|consumer)_' "$out_dir/native-local-scope.log"
  echo 'native_rtld_now=LOAD_REJECTED_FOR_UNRESOLVED_SYMBOL'
  echo
  echo '[Resolved RTLD_GLOBAL control]'
  grep -E '^(provider|default|consumer)_' "$out_dir/emscripten-global-scope.log"
} | tee "$out_dir/results.txt"
