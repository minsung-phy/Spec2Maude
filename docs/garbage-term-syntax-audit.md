# Garbage Term Syntax Audit

## Summary

This pass fixed garbage terms that came from the translator losing SpecTec syntax restrictions.

The intended rule is:

- constructors/operators return `SpectecTerminal`
- syntax categories are Maude sorts
- category membership is decided by `mb`, `cmb`, and `subsort`
- sequence arguments are parsed as `SpectecTerminals`, then checked by `XSeq` membership

This avoids making a term a category member just because an operator returned that category directly.

## Fixed Translator Gaps

### Sequence arguments

SpecTec arguments such as `instr*`, `val*`, `catch*`, `byte*`, and `list(X)` are now translated to source-derived sequence sorts such as:

```maude
sort InstrSeq .
subsort Instr < InstrSeq .
subsort InstrSeq < SpectecTerminals .
```

Constructor membership now checks the sequence category:

```maude
cmb CTORBLOCKA2(BLOCKTYPE1, INSTR-LIST-INSTR1) : Instr
  if BLOCKTYPE1 : Blocktype /\ INSTR-LIST-INSTR1 : InstrSeq .
```

### Empty sequence

`eps` is now represented by one shared least sort:

```maude
sort EmptySeq .
subsort EmptySeq < SpectecTerminals .
op eps : -> EmptySeq .
subsort EmptySeq < InstrSeq .
subsort EmptySeq < ValSeq .
```

This avoids having one overloaded `eps` declaration per sequence sort.

### Flat sequence categories

SpecTec flat syntax such as:

```spectec
syntax globaltype = mut? valtype
syntax tabletype = addrtype limits reftype
```

is now preserved as membership:

```maude
cmb (MUT1) (VALTYPE1) : Globaltype
  if MUT1 : Mut /\ VALTYPE1 : Valtype .

cmb eps (VALTYPE1) : Globaltype
  if VALTYPE1 : Valtype .

cmb (ADDRTYPE1) (LIMITS1) (REFTYPE1) : Tabletype
  if ADDRTYPE1 : Addrtype /\ LIMITS1 : Limits /\ REFTYPE1 : Reftype .
```

### Runtime configuration constructors

The semicolon configuration operators no longer return `State` or `Config` directly. They return `SpectecTerminal`; membership decides whether the term is a `State` or `Config`.

```maude
op _;_ : Store Frame -> SpectecTerminal [ctor] .
op _;_ : State SpectecTerminals -> SpectecTerminal [ctor] .

cmb (STORE1 ; FRAME1) : State
  if STORE1 : Store /\ FRAME1 : Frame .

cmb (STATE1 ; INSTR-LIST-INSTR1) : Config
  if STATE1 : State /\ INSTR-LIST-INSTR1 : InstrSeq .
```

## Checked Garbage Examples

These bad terms no longer reduce to their category sorts:

```maude
CTORBLOCKA2(CTORWRESULTA1(eps), CTORI32A0 CTORF64A0)
CTORGLOBALA2(CTORI32A0, CTORI64A0)
RECFrameA2(CTORI32A0 CTORF64A0, $empty-moduleinst)
RECStoreA10(CTORI32A0, ..., CTORI32A0)
($empty-store ; $empty-frame) ; CTORI32A0 CTORF64A0
```

They stay at `SpectecTerminal`, so they are constructible raw terms but not valid members of `Instr`, `Global`, `Frame`, `Store`, or `Config`.

## Remaining Review Item

`nonfuncs` still deserves professor review:

```spectec
syntax nonfuncs = global* mem* table* elem*
```

The generated membership is source-faithful, but Maude warns that the delimiter-free concatenation may match more than expected:

```maude
cmb (GLOBAL-LIST-GLOBAL1) (MEM-LIST-MEM1) (TABLE-LIST-TABLE1) (ELEM-LIST-ELEM1) : Nonfuncs
  if GLOBAL-LIST-GLOBAL1 : GlobalSeq
  /\ MEM-LIST-MEM1 : MemSeq
  /\ TABLE-LIST-TABLE1 : TableSeq
  /\ ELEM-LIST-ELEM1 : ElemSeq .
```

This is not a missed translator restriction. It is an ambiguity caused by representing several adjacent lists with one associative terminal-sequence operator.

## Remaining Warnings

Maude still warns about membership axioms over builtin associative operators and the generic terminal sequence operator `__`.

The tested syntax garbage examples are now blocked, but the `nonfuncs` warning should be discussed as a possible structural ambiguity in the Maude representation.

## Not Syntax Garbage

Some terms are syntax-valid but validation-invalid, for example an out-of-range local index. Those belong to the SpecTec validation/typechecker stage, not to the syntax membership layer.

