#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

MODE="${1:-auto}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
ARTIFACT_DIR="$ROOT_DIR/artifacts/$TIMESTAMP"
mkdir -p "$ARTIFACT_DIR"

DEFAULT_MAUDE="/Users/minsung/Dev/tools/Maude-3.5.1-macos-x86_64/maude"
if [[ -x "$DEFAULT_MAUDE" ]]; then
  MAUDE_BIN="${MAUDE_BIN:-$DEFAULT_MAUDE}"
else
  MAUDE_BIN="${MAUDE_BIN:-$(command -v maude || true)}"
fi

if [[ -z "$MAUDE_BIN" ]]; then
  echo "[ERROR] Maude binary not found. Set MAUDE_BIN or install maude." >&2
  exit 1
fi

if [[ "$MODE" != "current" && "$MODE" != "legacy" && "$MODE" != "legacy-safe" && "$MODE" != "auto" ]]; then
  echo "Usage: $0 [current|legacy|legacy-safe|auto]" >&2
  exit 1
fi

SPECTEC_FILES=(wasm-3.0/*.spectec)

translate_with_exe() {
  local exe="$1"
  local out_maude="$2"
  local out_err="$3"
  local out_log="$4"

  echo "[INFO] Building ${exe}.exe" | tee -a "$out_log"
  dune build "./${exe}.exe" >>"$out_log" 2>&1

  echo "[INFO] Translating with ${exe}.exe" | tee -a "$out_log"
  "./_build/default/${exe}.exe" "${SPECTEC_FILES[@]}" >"$out_maude" 2>"$out_err"
}

run_smoke() {
  local smoke_log="$1"
  "$MAUDE_BIN" -no-banner <<'EOF' >"$smoke_log" 2>&1
load wasm-exec
rew in WASM-FIB : steps(fib-config(i32v(5))) .
red in WASM-FIB-PROPS : modelCheck(mc-fib-config(i32v(5)), <> result-is(5)) .
red in WASM-FIB-PROPS : modelCheck(mc-fib-config(i32v(5)), [] ~ trap-seen) .
red in WASM-FIB-PROPS : modelCheck(mc(bench-add-config), <> result-is(42)) .
red in WASM-FIB-PROPS : modelCheck(mc(bench-add-config), [] ~ trap-seen) .
red in WASM-FIB-PROPS : modelCheck(mc(bench-muladd-config), <> result-is(47)) .
red in WASM-FIB-PROPS : modelCheck(mc(bench-muladd-config), [] ~ trap-seen) .
red in WASM-FIB-PROPS : modelCheck(mc(bench-local-config), <> result-is(1)) .
red in WASM-FIB-PROPS : modelCheck(mc(bench-local-config), [] ~ trap-seen) .
q
EOF
}

run_load_sanity() {
  local sanity_log="$1"
  "$MAUDE_BIN" -no-banner <<'EOF' >"$sanity_log" 2>&1
load wasm-exec
rew in WASM-FIB : fib-config(i32v(0)) .
q
EOF
}

validate_smoke() {
  local smoke_log="$1"

  if ! grep -q "rewrite in WASM-FIB : steps(fib-config(i32v(5)))" "$smoke_log"; then
    echo "[ERROR] fib rewrite command output not found in smoke log." >&2
    return 1
  fi

  if ! grep -q "result ExecConf:" "$smoke_log"; then
    echo "[ERROR] fib rewrite did not produce an ExecConf result." >&2
    return 1
  fi

  local bool_ok
  bool_ok="$(grep -c "^result Bool: true" "$smoke_log" || true)"
  if [[ "$bool_ok" -lt 8 ]]; then
    echo "[ERROR] expected >=8 successful modelCheck results, got ${bool_ok}." >&2
    return 1
  fi

  if grep -qiE "counterexample|Fatal error|stack overflow|deadlock" "$smoke_log"; then
    echo "[ERROR] smoke log contains failure markers." >&2
    return 1
  fi

  return 0
}

validate_load_sanity() {
  local sanity_log="$1"

  if ! grep -q "rewrite in WASM-FIB : fib-config(i32v(0))" "$sanity_log"; then
    echo "[ERROR] legacy-safe sanity rewrite command output not found." >&2
    return 1
  fi

  if ! grep -q "result ExecConf:" "$sanity_log"; then
    echo "[ERROR] legacy-safe sanity rewrite did not produce ExecConf." >&2
    return 1
  fi

  if grep -qiE "parse error|Fatal error|stack overflow" "$sanity_log"; then
    echo "[ERROR] legacy-safe sanity log contains fatal markers." >&2
    return 1
  fi

  return 0
}

run_mode() {
  local mode="$1"
  local exe
  if [[ "$mode" == "current" ]]; then
    exe="main"
  else
    exe="main_legacy"
  fi

  local mode_dir="$ARTIFACT_DIR/$mode"
  mkdir -p "$mode_dir"

  local run_log="$mode_dir/run.log"
  local smoke_log="$mode_dir/maude_smoke.log"
  local sanity_log="$mode_dir/maude_sanity.log"
  local out_maude="$mode_dir/output.maude"
  local out_err="$mode_dir/translate_err.txt"

  translate_with_exe "$exe" "$out_maude" "$out_err" "$run_log"
  cp "$out_maude" "$ROOT_DIR/output.maude"
  cp "$out_err" "$ROOT_DIR/translate_err.txt"

  if [[ "$mode" == "legacy-safe" ]]; then
    run_load_sanity "$sanity_log"
    validate_load_sanity "$sanity_log"
  else
    run_smoke "$smoke_log"
    validate_smoke "$smoke_log"
  fi

  echo "[OK] mode=${mode} passed. logs: $mode_dir"
}

if [[ "$MODE" == "auto" ]]; then
  echo "[INFO] AUTO mode: trying current first, then legacy-safe fallback if needed."
  if run_mode current; then
    echo "[DONE] AUTO selected current mode."
    exit 0
  fi

  echo "[WARN] Current mode failed; trying legacy-safe fallback..."
  run_mode legacy-safe
  echo "[DONE] AUTO selected legacy-safe mode (degraded verification guarantees)."
else
  run_mode "$MODE"
  echo "[DONE] mode=${MODE}"
fi
