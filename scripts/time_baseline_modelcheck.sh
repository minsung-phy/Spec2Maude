#!/usr/bin/env bash
set -u

usage() {
  cat <<'USAGE'
Usage:
  scripts/time_baseline_modelcheck.sh [N] [reach|trap|FORMULA] [TIMEOUT_SECONDS]

Examples:
  scripts/time_baseline_modelcheck.sh 2 reach 600
  scripts/time_baseline_modelcheck.sh 5 trap 1800
  scripts/time_baseline_modelcheck.sh 3 '<> result-is(2)' 0

Arguments:
  N                 Fibonacci input. Default: 5.
  reach             Checks <> result-is(fib(N)).
  trap              Checks [] ~ trap-seen.
  FORMULA           Raw LTL formula passed to modelCheck.
  TIMEOUT_SECONDS   0 means no timeout. Default: 0.

Output:
  Logs are written to logs/baseline_modelcheck_*.log.
USAGE
}

fib() {
  local n="$1"
  local a=0
  local b=1
  local i=0
  local tmp
  while [ "$i" -lt "$n" ]; do
    tmp="$b"
    b=$((a + b))
    a="$tmp"
    i=$((i + 1))
  done
  printf '%s\n' "$a"
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

N="${1:-5}"
MODE_OR_FORMULA="${2:-reach}"
TIMEOUT_SECONDS="${3:-0}"

case "$MODE_OR_FORMULA" in
  reach)
    EXPECTED="$(fib "$N")"
    FORMULA="<> result-is(${EXPECTED})"
    LABEL="reach"
    ;;
  trap)
    FORMULA="[] ~ trap-seen"
    LABEL="trap"
    ;;
  *)
    FORMULA="$MODE_OR_FORMULA"
    LABEL="custom"
    ;;
esac

if ! command -v maude >/dev/null 2>&1; then
  echo "error: maude not found in PATH" >&2
  exit 127
fi

mkdir -p logs

STAMP="$(date +%Y%m%d_%H%M%S)"
LOG="logs/baseline_modelcheck_N${N}_${LABEL}_${STAMP}.log"
TMP_INPUT="$(mktemp)"
trap 'rm -f "$TMP_INPUT"' EXIT

cat > "$TMP_INPUT" <<EOF
red in WASM-FIB-BS-PROPS : modelCheck(fib-config(i32v(${N})), ${FORMULA}) .
EOF

START_EPOCH="$(date +%s)"
START_ISO="$(date -Is)"

{
  echo "started_at: ${START_ISO}"
  echo "cwd: $(pwd)"
  echo "input_N: ${N}"
  echo "formula: ${FORMULA}"
  echo "timeout_seconds: ${TIMEOUT_SECONDS}"
  echo "command: maude -no-banner wasm-exec-bs.maude"
  echo "maude_input:"
  sed 's/^/  /' "$TMP_INPUT"
  echo "----- maude output -----"
} | tee "$LOG"

if [ "$TIMEOUT_SECONDS" = "0" ]; then
  /usr/bin/time -p maude -no-banner wasm-exec-bs.maude < "$TMP_INPUT" 2>&1 | tee -a "$LOG"
  STATUS="${PIPESTATUS[0]}"
else
  /usr/bin/time -p timeout "$TIMEOUT_SECONDS" maude -no-banner wasm-exec-bs.maude < "$TMP_INPUT" 2>&1 | tee -a "$LOG"
  STATUS="${PIPESTATUS[0]}"
fi

END_EPOCH="$(date +%s)"
END_ISO="$(date -Is)"
ELAPSED=$((END_EPOCH - START_EPOCH))

{
  echo "----- timing summary -----"
  echo "ended_at: ${END_ISO}"
  echo "elapsed_seconds_wall: ${ELAPSED}"
  echo "exit_status: ${STATUS}"
  if [ "$STATUS" = "124" ]; then
    echo "result: timeout"
  elif [ "$STATUS" = "0" ]; then
    echo "result: completed"
  else
    echo "result: failed"
  fi
  echo "log_file: ${LOG}"
} | tee -a "$LOG"

exit "$STATUS"
