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

echo "[1/8] Check WABT tools"
{
  command -v wasm2wat
  wasm2wat --version
  command -v wat2wasm
  wat2wasm --version
  command -v wasm-validate
  wasm-validate --version
  command -v wast2json
  wast2json --version
} >"$ARTIFACT_DIR/wabt.log" 2>&1

echo "[2/8] Build translator and Wasm frontend"
dune build ./main_bs.exe ./wasm_to_maude.exe >"$ARTIFACT_DIR/build.log" 2>&1

echo "[3/8] Regenerate output_bs.maude"
dune exec ./main_bs.exe -- wasm-3.0/*.spectec \
  > output_bs.maude \
  2> "$ARTIFACT_DIR/translate.log"

echo "[4/8] Structural invariants"
{
  echo "eq/ceq-valid:"
  grep -nE "^[[:space:]]*(eq|ceq) .* = valid" output_bs.maude || true
  echo
  echo "iter-empty/opt-empty:"
  grep -n "iter-empty\\|opt-empty" output_bs.maude || true
  echo
  echo "step-from-step-pure count:"
  (grep -n "step-from-step-pure-" output_bs.maude || true) | wc -l
  echo
  echo "forbidden translator hardcoding:"
  grep -n "Func-ok\\|Instrs-ok\\|Module-ok\\|Externaddr-ok\\|fib\\|CTORI32A0" translator_bs.ml || true
} | tee "$ARTIFACT_DIR/invariants.log"

echo "[5/8] Run WAT/Wasm benchmark smokes and external probes"
scripts/run_wasm_benchmarks.py \
  --cli _build/default/wasm_to_maude.exe \
  --maude "$MAUDE_BIN" \
  --max-external-files "${WASM_BENCH_LIMIT:-80}" \
  --max-file-bytes "${WASM_BENCH_MAX_BYTES:-1000000}" \
  --artifact-dir "${ARTIFACT_DIR#$ROOT_DIR/}/wasm-benchmarks" \
  > "$ARTIFACT_DIR/wasm_benchmarks.log" \
  2>&1

echo "[6/8] Run direct WAT runtime smokes"
{
  set -x
  dune exec ./wasm_to_maude.exe -- --maude "$MAUDE_BIN" --checked-run --run 5 wat_examples/fib.wat
  dune exec ./wasm_to_maude.exe -- --maude "$MAUDE_BIN" --checked-run --invoke-index 1 --run 5 wat_examples/fib-wrapper.wat
  dune exec ./wasm_to_maude.exe -- --maude "$MAUDE_BIN" --checked-run --run-main wat_examples/global-get.wat
  dune exec ./wasm_to_maude.exe -- --maude "$MAUDE_BIN" --checked-run --run-main wat_examples/memory-size.wat
  dune exec ./wasm_to_maude.exe -- --maude "$MAUDE_BIN" --checked-run --run-main wat_examples/table-size.wat
  dune exec ./wasm_to_maude.exe -- --maude "$MAUDE_BIN" --checked-run --run-main wat_examples/start-global.wat
  dune exec ./wasm_to_maude.exe -- --maude "$MAUDE_BIN" --checked-run --run-main wat_examples/data-load.wat
  dune exec ./wasm_to_maude.exe -- --maude "$MAUDE_BIN" --checked-run --run-main wat_examples/elem-call-ref.wat
  dune exec ./wasm_to_maude.exe -- --maude "$MAUDE_BIN" --checked-run --result-only --run-export main --arg-i32 41 --import-func 'env.bump=local.get 0 i32.const 1 i32.add' wat_examples/import-func.wat
  dune exec ./wasm_to_maude.exe -- --maude "$MAUDE_BIN" --checked-run --result-only --run-export main --import-global 'env.g=i32.const 77' wat_examples/import-global.wat
  dune exec ./wasm_to_maude.exe -- --maude "$MAUDE_BIN" --checked-run --result-only --run-export main wat_examples/import-memory.wat
  dune exec ./wasm_to_maude.exe -- --maude "$MAUDE_BIN" --checked-run --result-only --run-export main wat_examples/import-table.wat
} > "$ARTIFACT_DIR/wat_smokes.log" 2>&1

echo "[7/8] Run isolated C1 probe matrix"
if ! MAUDE_BIN="$MAUDE_BIN" C1_PROBE_TIMEOUT="${C1_PROBE_TIMEOUT:-8}" \
    scripts/run_c1_probe_matrix.py \
    > "$ARTIFACT_DIR/probe_matrix_runner.log" \
    2>&1; then
  echo "[WARN] C1 probe matrix has known diagnostic failures; see $ARTIFACT_DIR/probe_matrix_runner.log" \
    | tee "$ARTIFACT_DIR/probe_matrix.warning"
fi

echo "[8/8] Inventory generated rl/crl labels"
scripts/audit_output_bs_rules.py --artifact-dir "$ARTIFACT_DIR/rule-inventory" \
  > "$ARTIFACT_DIR/rule_inventory_runner.log" \
  2>&1
scripts/audit_non_isomorphic_helpers.py output_bs.maude \
  > "$ARTIFACT_DIR/non_isomorphic_helpers.md"

echo "[final] Classify Maude load warnings"
printf "load wasm-exec-bs\nq\n" | "$MAUDE_BIN" -no-banner \
  > "$ARTIFACT_DIR/maude_load.log" \
  2>&1
scripts/classify_maude_warnings.py "$ARTIFACT_DIR/maude_load.log" \
  | tee "$ARTIFACT_DIR/warnings.csv"

echo "[DONE] Artifacts: $ARTIFACT_DIR"
