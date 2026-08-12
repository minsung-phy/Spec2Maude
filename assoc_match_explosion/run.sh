#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
root=$(CDPATH= cd -- "$here/.." && pwd)
variant=${1:-both}
wasm2maude="$root/_build/default/bin/wasm2maude.exe"

build_harness() {
  name=$1
  "$wasm2maude" modelcheck "$here/fib.wasm" \
    --invoke fib \
    --arg i32:5 --arg i32:0 --arg i32:1 \
    --expect i32:5 --reject i32:6 \
    --semantics "$here/$name/builtins.maude" \
    -o "$here/fib-$name.maude"
}

run_variant() {
  name=$1
  build_harness "$name"
  maude -no-banner "$here/fib-$name.maude" \
    > "$here/logs/fib-$name.log" 2>&1
  if grep -Eq '^(Warning|Advisory|Error):' "$here/logs/fib-$name.log"; then
    echo "$name: Maude reported a warning, advisory, or error" >&2
    exit 1
  fi
  echo "$name: completed; see logs/fib-$name.log"
}

if [ ! -x "$wasm2maude" ]; then
  echo "missing $wasm2maude; run dune build first" >&2
  exit 1
fi

wat2wasm "$here/fib.wat" -o "$here/fib.wasm"
mkdir -p "$here/logs"

case "$variant" in
  baseline) run_variant baseline ;;
  sorted) run_variant sorted ;;
  both)
    run_variant baseline
    run_variant sorted
    ;;
  *)
    echo "usage: $0 [baseline|sorted|both]" >&2
    exit 2
    ;;
esac
