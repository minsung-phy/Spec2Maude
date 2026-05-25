#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

DEFAULT_MAUDE_ARM="/Users/minsung/Dev/tools/Maude-3.5.1-macos-arm64/maude"
DEFAULT_MAUDE_X86="/Users/minsung/Dev/tools/Maude-3.5.1-macos-x86_64/maude"
if [[ -x "$DEFAULT_MAUDE_ARM" ]]; then
  MAUDE_BIN="${MAUDE_BIN:-$DEFAULT_MAUDE_ARM}"
elif [[ -x "$DEFAULT_MAUDE_X86" ]]; then
  MAUDE_BIN="${MAUDE_BIN:-$DEFAULT_MAUDE_X86}"
else
  MAUDE_BIN="${MAUDE_BIN:-$(command -v maude || true)}"
fi

if [[ -z "$MAUDE_BIN" ]]; then
  echo "[ERROR] Maude binary not found. Set MAUDE_BIN." >&2
  exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
ARTIFACT_DIR="$ROOT_DIR/artifacts/c1-regression-$STAMP"
mkdir -p "$ARTIFACT_DIR"

echo "[1/7] Build translator and WAT frontend"
dune build ./main_bs.exe ./wat_to_maude_fib.exe >"$ARTIFACT_DIR/build.log" 2>&1

echo "[2/7] Regenerate output_bs.maude"
dune exec ./main_bs.exe -- wasm-3.0/*.spectec \
  > output_bs.maude \
  2> "$ARTIFACT_DIR/translate.log"

echo "[3/7] Structural invariants"
{
  echo "eq/ceq-valid:"
  grep -nE "^[[:space:]]*(eq|ceq) .* = valid" output_bs.maude || true
  echo
  echo "iter-empty/opt-empty:"
  grep -n "iter-empty\\|opt-empty" output_bs.maude || true
  echo
  echo "step-from-step-pure count:"
  grep -n "step-from-step-pure-" output_bs.maude | wc -l
  echo
  echo "forbidden translator hardcoding:"
  grep -n "Func-ok\\|Instrs-ok\\|Module-ok\\|Externaddr-ok\\|fib\\|CTORI32A0" translator_bs.ml || true
} | tee "$ARTIFACT_DIR/invariants.log"

echo "[4/7] Run focused WAT runtime smokes"
{
  set -x
  dune exec ./wat_to_maude_fib.exe -- --maude "$MAUDE_BIN" --run 5 examples/fib.wat
  dune exec ./wat_to_maude_fib.exe -- --maude "$MAUDE_BIN" --invoke-index 1 --run 5 examples/fib-wrapper.wat
  dune exec ./wat_to_maude_fib.exe -- --maude "$MAUDE_BIN" --run-main examples/global-get.wat
  dune exec ./wat_to_maude_fib.exe -- --maude "$MAUDE_BIN" --run-main examples/memory-size.wat
  dune exec ./wat_to_maude_fib.exe -- --maude "$MAUDE_BIN" --run-main examples/table-size.wat
  dune exec ./wat_to_maude_fib.exe -- --maude "$MAUDE_BIN" --run-main examples/start-global.wat
  dune exec ./wat_to_maude_fib.exe -- --maude "$MAUDE_BIN" --run-main examples/data-load.wat
  dune exec ./wat_to_maude_fib.exe -- --maude "$MAUDE_BIN" --run-main examples/elem-call-ref.wat
  dune exec ./wat_to_maude_fib.exe -- --maude "$MAUDE_BIN" --result-only --run-export main --arg-i32 41 --import-func 'env.bump=local.get 0 i32.const 1 i32.add' examples/import-func.wat
  dune exec ./wat_to_maude_fib.exe -- --maude "$MAUDE_BIN" --result-only --run-export main --import-global 'env.g=i32.const 77' examples/import-global.wat
  dune exec ./wat_to_maude_fib.exe -- --maude "$MAUDE_BIN" --result-only --run-export main examples/import-memory.wat
  dune exec ./wat_to_maude_fib.exe -- --maude "$MAUDE_BIN" --result-only --run-export main examples/import-table.wat
} > "$ARTIFACT_DIR/wat_smokes.log" 2>&1

echo "[5/7] Run isolated C1 probe matrix"
MAUDE_BIN="$MAUDE_BIN" C1_PROBE_TIMEOUT="${C1_PROBE_TIMEOUT:-8}" \
  scripts/run_c1_probe_matrix.py \
  > "$ARTIFACT_DIR/probe_matrix_runner.log" \
  2>&1

echo "[6/7] Inventory generated rl/crl labels"
scripts/audit_output_bs_rules.py --artifact-dir "$ARTIFACT_DIR/rule-inventory" \
  > "$ARTIFACT_DIR/rule_inventory_runner.log" \
  2>&1

echo "[7/7] Classify Maude load warnings"
printf "load wasm-exec-bs\nq\n" | "$MAUDE_BIN" -no-banner \
  > "$ARTIFACT_DIR/maude_load.log" \
  2>&1
scripts/classify_maude_warnings.py "$ARTIFACT_DIR/maude_load.log" \
  | tee "$ARTIFACT_DIR/warnings.csv"

echo "[DONE] Artifacts: $ARTIFACT_DIR"
