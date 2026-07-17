set -eu

output=$1

expect () {
  grep -Fqx "  $1" "$output"
}

expect 'cmb comptype.func-sym(RESULTTYPE:SpectecTerminal, RESULTTYPE2:SpectecTerminal) : SpectecTerminal'
expect 'cmb moduletype.sym(EXTERNTYPE_STAR:SpectecTerminals, EXTERNTYPE_STAR2:SpectecTerminals) : SpectecTerminal'
expect 'cmb instr.if-else(BLOCKTYPE:SpectecTerminal, INSTR_STAR:SpectecTerminals, INSTR_STAR2:SpectecTerminals) : SpectecTerminal'
expect 'cmb instr.br-on-cast(LABELIDX:SpectecTerminal, REFTYPE:SpectecTerminal, REFTYPE2:SpectecTerminal) : SpectecTerminal'
expect 'cmb instr.br-on-cast-fail(LABELIDX:SpectecTerminal, REFTYPE:SpectecTerminal, REFTYPE2:SpectecTerminal) : SpectecTerminal'
expect 'cmb instr.table-copy(TABLEIDX:SpectecTerminal, TABLEIDX2:SpectecTerminal) : SpectecTerminal'
expect 'cmb instr.memory-copy(MEMIDX:SpectecTerminal, MEMIDX2:SpectecTerminal) : SpectecTerminal'
expect 'cmb instr.array-copy(TYPEIDX:SpectecTerminal, TYPEIDX2:SpectecTerminal) : SpectecTerminal'
expect 'cmb instr.label-sym-sym(N:Nat, INSTR_STAR:SpectecTerminals, INSTR_STAR2:SpectecTerminals) : SpectecTerminal'
expect 'cmb import.import(NAME:SpectecTerminal, NAME2:SpectecTerminal, EXTERNTYPE:SpectecTerminal) : SpectecTerminal'
expect 'cmb instrtype.sym(RESULTTYPE:SpectecTerminal, LOCALIDX_STAR:SpectecTerminals, RESULTTYPE2:SpectecTerminal) : SpectecTerminal'

if awk '
  /^  cmb [A-Za-z0-9.-]+\([^()]*\) :/ {
    line = $0
    sub(/^  cmb [^(]*\(/, "", line)
    sub(/\) :.*/, "", line)
    count = split(line, arg, /, */)
    delete seen
    for (i = 1; i <= count; i++)
      if (seen[arg[i]]++) {
        print $0
        duplicate = 1
        break
      }
  }
  END { exit duplicate ? 0 : 1 }
' "$output"
then
  echo 'generated constructor membership reused a component occurrence' >&2
  exit 1
fi
