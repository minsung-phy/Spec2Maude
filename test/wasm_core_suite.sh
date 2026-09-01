#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
suite="$root/benchmarks/wasm-spec/test/core"
semantics="$root/translator/backend/semantics.maude"
maude_bin=${MAUDE:-maude}
short_timeout=${SHORT_TIMEOUT:-300}
long_timeout=${LONG_TIMEOUT:-3600}
steps=${STEPS:-1000000000000}
call_depth=${CALL_DEPTH:-256}
timestamp=$(date '+%Y%m%d-%H%M%S')
results=${RESULT_DIR:-"${TMPDIR:-/tmp}/spec2maude-wasm-core-$timestamp"}

usage() {
  cat <<EOF
usage: test/wasm_core_suite.sh

Runs all 258 official WebAssembly core .wast files with a ${short_timeout}s
wall-clock timeout, then reruns only TIMEOUT files with a ${long_timeout}s
timeout. Results are written to:

  $results

Environment variables:
  MAUDE          Maude executable (default: maude)
  RESULT_DIR     new result directory
  SHORT_TIMEOUT  first-stage timeout in seconds (default: 300)
  LONG_TIMEOUT   retry timeout in seconds (default: 3600)
  STEPS          rewrite budget (default: 1000000000000)
  CALL_DEPTH     WAST call-depth limit (default: 256)
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if [[ $# -ne 0 ]]; then
  usage >&2
  exit 2
fi
if [[ -e "$results" ]]; then
  echo "wasm_core_suite: result path already exists: $results" >&2
  exit 1
fi
if ! command -v "$maude_bin" >/dev/null 2>&1; then
  echo "wasm_core_suite: Maude executable not found: $maude_bin" >&2
  echo "wasm_core_suite: set MAUDE=/absolute/path/to/maude" >&2
  exit 1
fi

file_count=$(find "$suite" -type f -name '*.wast' | wc -l | tr -d ' ')
if [[ "$file_count" != 258 ]]; then
  echo "wasm_core_suite: expected 258 .wast files, found $file_count" >&2
  exit 1
fi

mkdir -p "$results/stage-300/logs" "$results/stage-3600"
printf '%s\n' \
  "suite=$suite" \
  "semantics=$semantics" \
  "maude=$maude_bin" \
  "short_timeout=$short_timeout" \
  "long_timeout=$long_timeout" \
  "steps=$steps" \
  "call_depth=$call_depth" \
  "started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  >"$results/settings.txt"

write_command() {
  local path=$1
  shift
  printf '%q ' "$@" >"$path"
  printf '\n' >>"$path"
}

run_suite() {
  local input=$1
  local timeout=$2
  local report=$3
  local logs=$4
  local stdout=$5
  local stderr=$6
  local command_file=$7
  local command=(
    dune exec bin/wasm2maude.exe -- suite-run "$input"
    --semantics "$semantics"
    --maude "$maude_bin"
    --timeout "$timeout"
    --steps "$steps"
    --call-depth "$call_depth"
    --log-dir "$logs"
    -o "$report"
  )
  write_command "$command_file" "${command[@]}"
  (
    cd "$root"
    "${command[@]}"
  ) >"$stdout" 2>"$stderr" || true
  if [[ ! -s "$report" ]]; then
    echo "wasm_core_suite: runner did not produce $report" >&2
    exit 1
  fi
}

stage300="$results/stage-300"
run_suite "$suite" "$short_timeout" \
  "$stage300/report.tsv" "$stage300/logs" \
  "$stage300/stdout" "$stage300/stderr" "$stage300/command.txt"

rows=$(awk 'NR > 1 { count++ } END { print count + 0 }' "$stage300/report.tsv")
unique=$(awk -F '\t' 'NR > 1 { seen[$6] = 1 } END { for (x in seen) count++; print count + 0 }' "$stage300/report.tsv")
if [[ "$rows" != 258 || "$unique" != 258 ]]; then
  echo "wasm_core_suite: stage-300 report is incomplete ($rows rows, $unique unique sources)" >&2
  exit 1
fi

retries="$results/stage-3600/retries.tsv"
head -n 1 "$stage300/report.tsv" >"$retries"
retry_index=0
while IFS=$'\t' read -r status _seconds _commands _checked _runtime source _detail; do
  [[ "$status" == "TIMEOUT" ]] || continue
  retry_index=$((retry_index + 1))
  retry_dir=$(printf '%s/retry-%04d' "$results/stage-3600" "$retry_index")
  mkdir -p "$retry_dir/logs"
  run_suite "$source" "$long_timeout" \
    "$retry_dir/report.tsv" "$retry_dir/logs" \
    "$retry_dir/stdout" "$retry_dir/stderr" "$retry_dir/command.txt"
  tail -n +2 "$retry_dir/report.tsv" >>"$retries"
done < <(tail -n +2 "$stage300/report.tsv")

awk -F '\t' '
  NR == FNR {
    if (FNR > 1) retry[$6] = $0
    next
  }
  FNR == 1 { print; next }
  $1 == "TIMEOUT" && ($6 in retry) { print retry[$6]; next }
  { print }
' "$retries" "$stage300/report.tsv" >"$results/final.tsv"

final_rows=$(awk 'NR > 1 { count++ } END { print count + 0 }' "$results/final.tsv")
final_unique=$(awk -F '\t' 'NR > 1 { seen[$6] = 1 } END { for (x in seen) count++; print count + 0 }' "$results/final.tsv")
if [[ "$final_rows" != 258 || "$final_unique" != 258 ]]; then
  echo "wasm_core_suite: final report is incomplete ($final_rows rows, $final_unique unique sources)" >&2
  exit 1
fi

printf 'status\tcount\n' >"$results/summary.tsv"
awk -F '\t' '
  NR > 1 { count[$1]++ }
  END {
    split("PASS WRONG_RESULT UNSUPPORTED FRONTEND_ERROR MAUDE_ERROR STUCK STEP_LIMIT TIMEOUT", order, " ")
    for (i = 1; i <= 8; i++) print order[i] "\t" count[order[i]]
  }
' "$results/final.tsv" >>"$results/summary.tsv"

printf 'finished=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$results/settings.txt"
cat "$results/summary.tsv"
echo "wasm_core_suite: final report: $results/final.tsv"
echo "wasm_core_suite: logs: $results"

non_pass=$(awk -F '\t' 'NR > 1 && $1 != "PASS" { count++ } END { print count + 0 }' "$results/final.tsv")
if [[ "$non_pass" != 0 ]]; then
  exit 1
fi
