# Header / Prelude Hardcoding Limitation

This note separates unavoidable Maude representation substrate from current
Wasm-specific or legacy hardcoding that should be cleaned before claiming a
generic SpecTec-to-Maude translator for non-Wasm specs such as P4.

## Current Safe State

- `output_bs.maude` is generated from `translator_bs.ml`; it is not manually
  patched as final output.
- Strict validation source-rule lowering is structurally complete: source
  validation rules are emitted as primary `rl/crl`, not `eq/ceq = valid`.
- No `eq/ceq ... = valid`, `iter-empty`, or `opt-empty` validation leftovers
  remain in the generated output.
- The remaining `WasmTerminal` / `WasmTerminals` / `WasmType` /
  `WasmTypes` names are accepted for the current Wasm baseline, but they are
  not yet suitable as-is for a language-independent backend.

## Generic Substrate That Will Still Exist

Some representation layer is unavoidable in Maude:

- a carrier sort for SpecTec terms;
- a sequence sort and `eps`/concatenation for `*`;
- record item/projection/update machinery for SpecTec record syntax;
- generated category membership or typed constructors;
- generated support for source meta-expressions such as sequence indexing
  `xs[i*]` and star-map shapes.

These should eventually be generated or parameterized as generic SpecTec
prelude, not maintained as Wasm-specific hand-written infrastructure.

## Current Hardcoding / Genericity Debt

The current `dsl/pretype.maude` and generated header still expose Wasm-flavored
names and assumptions:

- `WasmTerminal`, `WasmTerminals`, `WasmType`, `WasmTypes`;
- fixed generic record constructor `{_} : RecordItems -> WasmTerminal`;
- fixed sequence concatenation over `WasmTerminals`;
- fixed execution/context support modules in `DSL-EXEC`;
- Wasm-specific index-like subsort declarations in the generated header.

These are not all semantic shortcuts, but they are genericity blockers for P4.

## Typed Record Obstruction

The biggest blocker to making every source-unconditional validation rule an
unconditional Maude `rl` is record-shaped syntax such as:

```spectec
var C : context

rule Instr_ok/nop:
  C |- NOP : eps -> eps
```

Current generated Maude still needs:

```maude
crl [instr-ok-nop] :
  Instr-ok(C, CTORNOPA0, CTORARROWA3(eps, eps, eps))
  =>
  valid
    if $is-spectec-context(C) .
```

The guard is not a source rule premise. It is an executable encoding of the
implicit source binder `C : context`.

Two experiments explain why this is not a one-line `dsl/pretype` fix:

- Declaring `op {_} : RecordItems -> Context` makes matching work, but makes
  every record a `Context`.
- Declaring a fixed-field context operator for the exact source record shape
  makes matching work, but then generic `value` projection no longer reduces
  on the typed parse unless source-record-specific projection/update equations
  are generated. Those equations also need precise field sequence/category
  sorts to avoid accepting malformed records.

## Required Future Design

To remove `$is-spectec-*` binder guards without losing soundness:

1. Parameterize or generate the generic carrier names, e.g. move from
   `WasmTerminal` toward a language-neutral carrier such as `SpecTecTerm`.
2. Generate source-shaped record constructors from `StructT` declarations.
3. Generate record projection/update equations from source record fields.
4. Generate precise sequence/category sorts or an equivalent source-faithful
   representation so record fields are not over-broad.
5. Only then preserve record-shaped binder variables as native Maude sorts and
   emit source-unconditional rules as unconditional `rl`.

## Professor-Facing Question

Should C1 accept executable `$is-spectec-*` binder guards as representation
substrate for broad records, or must C1 include the deeper typed record/sequence
sort redesign so source-unconditional rules become unconditional Maude rules?
