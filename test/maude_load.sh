#!/usr/bin/env bash
set -euo pipefail

root=${1:?usage: maude_load.sh REPOSITORY_ROOT}
maude_bin=${MAUDE:-maude}

if ! command -v "$maude_bin" >/dev/null 2>&1; then
  echo "maude_load: skipped (set MAUDE or add maude to PATH)"
  exit 0
fi

log=$(mktemp)
trap 'rm -f "$log"' EXIT

(cd "$root" && "$maude_bin" -no-banner translator/backend/semantics.maude) >"$log" 2>&1
cat "$log"

if grep -E '(^|[[:space:]])(Warning:|Advisory:|\*\*\*)' "$log" >/dev/null; then
  echo "maude_load: load produced diagnostics" >&2
  exit 1
fi
