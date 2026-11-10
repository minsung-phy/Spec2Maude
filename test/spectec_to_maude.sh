#!/usr/bin/env bash
set -euo pipefail

# For each Wasm version: translate spectec/wasm-VERSION, compare with the
# checked-in generated output, and load it with its builtins
# (translator/backend/main*.maude) without Maude diagnostics.

root=$(cd "$(dirname "$0")/.." && pwd)
maude_bin=${MAUDE:-maude}
work=$(mktemp -d "${TMPDIR:-/tmp}/spec2maude-translation.XXXXXX")
trap 'rm -rf "$work"' EXIT

if ! command -v "$maude_bin" >/dev/null 2>&1; then
  echo "spectec_to_maude: Maude executable not found: $maude_bin" >&2
  echo "spectec_to_maude: set MAUDE=/absolute/path/to/maude" >&2
  exit 1
fi

(cd "$root" && dune build bin/spec2maude.exe)
spec2maude="$root/_build/default/bin/spec2maude.exe"

# version, expected file count, generated directory, main file, builtin files
# (the translator avoids their op names)
check() {
  local version=$1 expected_count=$2 generated=$3 main=$4
  shift 4
  local builtins=("$@")
  local source_dir="$root/spectec/wasm-$version"
  local file_count
  file_count=$(find "$source_dir" -maxdepth 1 -type f -name '*.spectec' | wc -l | tr -d ' ')
  if [[ "$file_count" != "$expected_count" ]]; then
    echo "spectec_to_maude: wasm-$version: expected $expected_count SpecTec files, found $file_count" >&2
    exit 1
  fi

  local out="$work/$version"
  mkdir -p "$out/translator/$generated" "$out/translator/backend" "$out/translator/builtins"
  "$spec2maude" -o "$out/translator/$generated/output.maude" \
    --builtins "${builtins[@]/#/$root/translator/builtins/}" "$source_dir"/*.spectec

  for name in types.maude output.maude; do
    if ! cmp -s "$root/translator/$generated/$name" "$out/translator/$generated/$name"; then
      echo "spectec_to_maude: wasm-$version: generated output differs from translator/$generated/$name" >&2
      echo "spectec_to_maude: regenerate it with: dune exec bin/spec2maude.exe -- -o translator/$generated/output.maude --builtins ${builtins[*]/#/translator/builtins/} spectec/wasm-$version/*.spectec" >&2
      exit 1
    fi
  done

  cp "$root"/translator/backend/*.maude "$out/translator/backend/"
  cp "$root"/translator/builtins/*.maude "$out/translator/builtins/"
  local log="$out/maude.log"
  (cd "$out" && "$maude_bin" -no-banner "translator/backend/$main" </dev/null) >"$log" 2>&1
  if grep -E '(^|[[:space:]])(Warning:|Advisory:|\*\*\*)' "$log" >/dev/null; then
    cat "$log"
    echo "spectec_to_maude: wasm-$version: Maude load produced diagnostics" >&2
    exit 1
  fi
  echo "spectec_to_maude: wasm-$version PASS ($file_count files)"
}

check 3.0 21 generated main.maude core.maude vector.maude wasm-3.0.maude
check 2.0 9 generated/wasm-2.0 main-wasm-2.0.maude core.maude vector.maude wasm-2.0.maude
check 1.0 9 generated/wasm-1.0 main-wasm-1.0.maude core.maude wasm-1.0.maude
