#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT_DIR/benchmarks/external"
mkdir -p "$DEST"

clone_or_update() {
  local name="$1"
  local url="$2"
  local dir="$DEST/$name"
  if [[ -d "$dir/.git" ]]; then
    echo "[update] $name"
    git -C "$dir" pull --ff-only
  else
    echo "[clone] $name <- $url"
    git clone --depth 1 "$url" "$dir"
  fi
}

clone_or_update webassembly-spec https://github.com/WebAssembly/spec.git
clone_or_update wasmbench https://github.com/sola-st/WasmBench.git
clone_or_update wasm-r3 https://github.com/doehyunbaek/wasm-r3.git
clone_or_update wasm-coremark https://github.com/wasm3/wasm-coremark.git

cat <<EOF

[done] benchmark repositories are under:
  $DEST

Notes:
- WebAssembly/spec is the official conformance/spec test source.
- WasmBench is a real-world Wasm benchmark corpus used by WebAssembly research.
- Wasm-R3 is the released artifact for realistic standalone Wasm benchmarks.
- wasm-coremark is the Wasm3 CoreMark port.
- Some real-world benchmarks require WASI/browser imports; run_wasm_benchmarks.py
  classifies those failures instead of hiding them.
EOF
