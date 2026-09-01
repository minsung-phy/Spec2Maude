#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
source_dir="$root/spectec/wasm-3.0"
expected="$root/translator/generated/output.maude"
maude_bin=${MAUDE:-maude}
work=$(mktemp -d "${TMPDIR:-/tmp}/spec2maude-translation.XXXXXX")
trap 'rm -rf "$work"' EXIT

file_count=$(find "$source_dir" -maxdepth 1 -type f -name '*.spectec' | wc -l | tr -d ' ')
if [[ "$file_count" != 21 ]]; then
  echo "spectec_to_maude: expected 21 SpecTec files, found $file_count" >&2
  exit 1
fi

mkdir -p "$work/translator/backend" "$work/translator/generated"
output="$work/translator/generated/output.maude"

(
  cd "$root"
  dune exec bin/spec2maude.exe -- -o "$output"
)

grep -Fq 'mod SPEC2MAUDE-GENERATED is' "$output"
grep -Fq 'protecting SPECTEC-SUPPORT .' "$output"

if ! cmp -s "$expected" "$output"; then
  echo "spectec_to_maude: generated output differs from $expected" >&2
  echo "spectec_to_maude: regenerate it with: dune exec bin/spec2maude.exe --" >&2
  exit 1
fi

if ! command -v "$maude_bin" >/dev/null 2>&1; then
  echo "spectec_to_maude: Maude executable not found: $maude_bin" >&2
  echo "spectec_to_maude: set MAUDE=/absolute/path/to/maude" >&2
  exit 1
fi

cp "$root/translator/backend/semantics.maude" "$work/translator/backend/"
cp "$root/translator/backend/relation-backends.maude" "$work/translator/backend/"
cp "$root/translator/backend/builtins.maude" "$work/translator/backend/"
cp -R "$root/translator/backend/spectec-support" "$work/translator/backend/"

log="$work/maude.log"
(
  cd "$work"
  "$maude_bin" -no-banner translator/backend/semantics.maude
) >"$log" 2>&1
cat "$log"

if grep -E '(^|[[:space:]])(Warning:|Advisory:|\*\*\*)' "$log" >/dev/null; then
  echo "spectec_to_maude: Maude load produced diagnostics" >&2
  exit 1
fi

echo "spectec_to_maude: PASS ($file_count files)"
