#!/usr/bin/env bash
set -uo pipefail

# Non-Wasm examples. Each test/non-wasm/NAME/ has
#   p.spectec       the source
#   commands.maude  Maude search commands
#   expected        "Unsupported" (translation must fail with an Unsupported
#                   diagnostic), or, per command, the echoed command followed by
#                   its solution bindings in sorted order.
#   forbidden       (optional) lines that must not occur in the generated
#                   out.maude, each matched as a fixed string.
#   builtins.maude  (optional) passed to the translator with --builtins.
# An example passes when the translator's result matches `expected` and the
# generated Maude loads without diagnostics. Usage: test/non_wasm.sh [NAME...]

root=$(cd "$(dirname "$0")/.." && pwd)
maude_bin=${MAUDE:-maude}
work=$(mktemp -d "${TMPDIR:-/tmp}/spec2maude-non-wasm.XXXXXX")
trap 'rm -rf "$work"' EXIT

if ! command -v "$maude_bin" >/dev/null 2>&1; then
  echo "non_wasm: Maude executable not found: $maude_bin" >&2
  echo "non_wasm: set MAUDE=/absolute/path/to/maude" >&2
  exit 1
fi

(cd "$root" && dune build bin/spec2maude.exe) || exit 1
spec2maude="$root/_build/default/bin/spec2maude.exe"
backend="$root/translator/backend"

# Keep each echoed command and the binding lines of its solutions, with the
# bindings of one command sorted (search order is not part of the expectation).
solutions() {
  awk '/^search / { n++; print n "\t0\t" $0; next }
       / --> /    { print n "\t1\t" $0 }' "$1" |
    sort -t "$(printf '\t')" -k1,1n -k2,2n -k3 | cut -f3-
}

# name -> prints the actual result; returns nonzero on a Maude load diagnostic
run() {
  local dir=$1 out=$2
  local builtins=()
  [[ -f "$dir/builtins.maude" ]] && builtins=(--builtins "$dir/builtins.maude")
  if ! "$spec2maude" -o "$out/out.maude" ${builtins[@]+"${builtins[@]}"} "$dir/p.spectec" >"$out/translate.log" 2>&1; then
    if grep -q 'translation error: Unsupported' "$out/translate.log"; then
      echo Unsupported
    else
      echo "translation failed without an Unsupported diagnostic:"
      cat "$out/translate.log"
    fi
    return 0
  fi
  if [[ -f "$dir/forbidden" ]]; then
    while IFS= read -r line; do
      if grep -Fq -- "$line" "$out/out.maude"; then
        echo "out.maude contains: $line"
      fi
    done <"$dir/forbidden"
  fi
  {
    echo "load $backend/spectec-sorts.maude"
    echo "load $out/types.maude"
    echo "load $backend/spectec-semantics.maude"
    echo "load $out/out.maude"
    cat "$dir/commands.maude"
  } >"$out/run.maude"
  "$maude_bin" -no-banner "$out/run.maude" </dev/null >"$out/maude.log" 2>&1
  solutions "$out/maude.log"
  if grep -E '(^|[[:space:]])(Warning:|Advisory:)' "$out/maude.log" >/dev/null; then
    grep -E -A3 '(^|[[:space:]])(Warning:|Advisory:)' "$out/maude.log"
    return 1
  fi
}

if (($# > 0)); then names=("$@"); else
  names=()
  for d in "$root"/test/non-wasm/*/; do names+=("$(basename "$d")"); done
fi

failed=0
for name in "${names[@]}"; do
  dir="$root/test/non-wasm/$name"
  out="$work/$name"
  mkdir -p "$out"
  run "$dir" "$out" >"$out/actual" 2>&1
  load_ok=$?
  if ((load_ok == 0)) && cmp -s "$dir/expected" "$out/actual"; then
    echo "non_wasm: $name PASS"
  else
    failed=$((failed + 1))
    echo "non_wasm: $name FAIL"
    ((load_ok == 0)) || echo "  (Maude load produced diagnostics)"
    diff -u --label expected --label actual "$dir/expected" "$out/actual" | sed 's/^/  /'
  fi
done

echo "non_wasm: $((${#names[@]} - failed))/${#names[@]} PASS"
((failed == 0))
