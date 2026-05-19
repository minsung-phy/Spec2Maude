# Strict Validation Lowering Summary

Updated: 2026-05-20

## Result

The strict C1 validation-lowering structural audit is complete.

C1 strict policy is:

- one SpecTec source relation rule maps to one primary Maude `rl` / `crl`;
- no derived validation rules;
- no `iter-empty` or `opt-empty` executable variants;
- validation failures are documented as limitations unless they are caused by a generic translator bug.

Current structural result:

```text
281 strict source-rule targets
-> 281 primary Maude rl/crl rules
```

Every strict source target now has a primary generated rewrite rule. No source target remains lowered as `eq` / `ceq ... = valid`.

## Count Reconciliation

The earlier mechanical count was:

- old raw `eq` / `ceq ... = valid`: 299;
- footer / executable leftovers: 6;
- old mechanical non-footer rows: 293.

The corrected strict source-rule target count is 281.

The apparent `293 -> 281` gap is a counting and mapping issue, not a missing-rule issue. The old mechanical non-footer count included duplicate / split rows for several source rules that now correctly appear once in strict C1. The current strict output also includes `eval-expr-r0`, a source rule that was not represented in the old `eq` / `ceq ... = valid` set. After accounting for these differences, the strict source target set is 281.

## Per-File Coverage

| Source file / family | Strict targets | Primary rl/crl matched |
|---|---:|---:|
| `wasm-3.0/2.1-validation.types.spectec` | 42 | 42 |
| `wasm-3.0/2.2-validation.subtyping.spectec` | 50 | 50 |
| `wasm-3.0/2.3-validation.instructions.spectec` | 140 | 140 |
| `wasm-3.0/2.4-validation.modules.spectec` | 28 | 28 |
| `wasm-3.0/4.1-execution.values.spectec` + `Eval_expr` | 21 | 21 |
| **Total** | **281** | **281** |

## Structural Checks

- All strict source targets have primary generated `rl` / `crl` rules.
- No strict source target remains as `eq` / `ceq ... = valid`.
- No derived validation labels containing `iter-empty` or `opt-empty` remain.
- Source-rule footer duplicates for `Expand`, `Num-ok`, and singleton
  `Val-ok` have been removed from the generator.
- Remaining `eq` / `ceq ... = valid` statements are non-source footer /
  executable leftovers only:
  - sequence-shaped `Val-ok` list-lifting for harness/prelude use.

Detailed audit artifacts are under `docs/c1-validation/`.

## Concrete Successes

### 2.1 Validation Types

Successful representative tests include:

- `Numtype-ok`;
- `Vectype-ok`;
- `Heaptype-ok` for concrete abstract heap types;
- `Reftype-ok`;
- `Valtype-ok` variants;
- `Resulttype-ok` for a nonempty singleton result type;
- `Packtype-ok`;
- `Storagetype-ok`.

### 2.2 Validation Subtyping

Successful representative tests include:

- `Numtype-sub`;
- `Vectype-sub`;
- `Heaptype-sub`, for example `i31 <: eq`;
- `Reftype-sub` for a non-null reference subtype case;
- `Valtype-sub`;
- `Resulttype-sub` for a singleton result type.

### 2.3 Validation Instructions

Successful representative tests include:

- `Instr-ok` for `NOP`;
- `Instr-ok` for `DROP`;
- `Instrs-ok` for the empty instruction sequence;
- `Instr-const`;
- `Expr-const`.

### 2.4 Validation Modules

Successful representative tests include:

- `Types-ok` for an empty type sequence;
- `Globals-ok` for an empty global sequence;
- `Datamode-ok` for passive data mode;
- `Data-ok` for a passive data segment;
- `Local-ok` for a simple local declaration;
- `Mem-ok` for a simple memory type.

### 4.1 Values And Eval_expr

Successful representative tests include:

- `Num-ok`;
- `Vec-ok`;
- `Ref-ok/null`;
- `Ref-ok/i31`;
- `Ref-ok/host`;
- `Val-ok/num`;
- `Val-ok/vec`;
- `Eval_expr`.

## Stuck Tests And Limitation Categories

### Empty `*` Premises

Examples:

- `Resulttype-ok(C, eps)`;
- `Resulttype-sub(C, eps, eps)`;
- `Instrtype-ok(C, arrow(eps, eps, eps))`;
- `Instrtype-sub(C, arrow(eps, eps, eps), arrow(eps, eps, eps))`;
- `Instr-ok/unreachable`, through its dependency on strict-empty `Instrtype-ok`.

Strict C1 preserves the iterated premise structurally. Without derived `iter-empty` rules, plain Maude rewriting does not discharge these empty-list cases.

### Witness Synthesis And Local-Index Premises

Examples:

- `Instrs-ok(C, CTORNOPA0, arrow(eps, eps, eps))`;
- module-level constant-expression validation that delegates through `Expr-ok` / `Instrs-ok`.

`Instrs-ok/seq` contains an intermediate witness such as `TS2`, produced by one premise and consumed by another. The current `Judgement => valid` encoding does not synthesize that witness. Some probes also expose `index(value('LOCALS, C), eps)` reducing to a stuck lookup shape.

### Step/ctxt-instrs Executability

The strict single `Step/ctxt-instrs` rule is structurally close to the SpecTec source rule, but Maude does not combine the needed associative split with the conditional rewrite premise in some label/br suffix cases. Label-related `step-from-step-pure-*` shortcuts remain as documented executable debt, not as C1-final structure.

### Concrete Store / Harness Lookup

Example:

- `Externaddr-ok/func` with `fib-store`.

The generated source rule needs `index(value('FUNCS, s), a)` to expose a function instance and project `TYPE`. The current concrete harness/store shape does not discharge that premise in the ground probe.

### Footer / Prelude Debt

Historical footer duplicates for `Expand`, `Num-ok`, and singleton `Val-ok`
were removed after confirming that the source-generated primary `crl`s already
exist. The remaining sequence-shaped `Val-ok` footer equations are classified
as executable harness/prelude leftovers, not source-rule targets.

## Translator Fixes Applied During This Audit

Two generic translator fixes were applied while preserving strict C1 structure:

1. Generated syntax/category predicates were renamed to `$is-spectec-<sort>` to avoid collisions with real SpecTec helper definitions such as `$is_packtype`.
2. DecD LHS argument lowering now uses `translate_arg`, preserving `TypA` / syntax arguments such as `syntax X`.

No derived validation rules were reintroduced by these fixes.

## Follow-Up

Use `281 / 281` as the strict validation-lowering coverage number. Executability gaps should be tracked as C1 limitations unless the fix is a generic isomorphic translator correction. Witness synthesis, mode-aware validation solving, and analysis-oriented execution control are candidates for C2 unless explicitly accepted into C1.
