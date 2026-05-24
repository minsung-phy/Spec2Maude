# Spec2Maude C1 Status

Updated: 2026-05-24

This is the current handoff document for the C1 baseline. Read this together
with `docs/limitation.md` before changing `translator_bs.ml`.

## One-Line State

The C1 WebAssembly SpecTec-to-Maude baseline is structurally covered and mostly
cleaned, but it is not yet a fully executable semantics for every generated
rule. The remaining decisions are about C1/C2 boundaries, not missing source
coverage.

## Current C1 Target

C1 means a faithful, relation-preserving baseline:

1. SpecTec syntax / def / rule structure and intent should be preserved.
2. Variable names and Maude internal names may differ.
3. Source-absent helpers, rules, conditions, or functions should not remain in
   the C1 core unless they are unavoidable representation substrate or
   explicitly accepted.
4. SpecTec unconditional rule should lower to Maude unconditional rule;
   conditional rule should lower to Maude conditional rule.
5. SpecTec `def` should lower to Maude `eq/ceq`; SpecTec `rule` should lower
   to Maude `rl/crl`.

## What To Read First

Use this order in a fresh Codex chat:

1. `STATUS.md`
2. `docs/limitation.md`
3. `docs/HowToTest.md`
4. `artifacts/current-rule-execution-audit-20260524_213453/summary.md`
5. `artifacts/c1-probe-matrix-20260524_225223/probe_summary.md`

Archive docs under `docs/archive/` are evidence/history. Do not treat them as
the current state unless a current document explicitly points there.

## Build And Regenerate

```bash
dune build ./main_bs.exe
dune exec ./main_bs.exe -- wasm-3.0/*.spectec > output_bs.maude
```

`wasm-exec-bs.maude` loads `builtins.maude`, which then loads the generated
core. Do not forget `builtins.maude` when moving machines or committing.

## Current Structural Facts

- WebAssembly SpecTec source files audited: 21 / 21.
- Syntax declarations covered: 249 / 249.
- Def declarations/equations covered: 1272 / 1272.
- Relation declarations covered: 82 / 82.
- Rule declarations covered: 499 / 499.
- Missing source constructs currently known: 0.
- Strict validation source-rule targets: 281 / 281 primary `rl/crl`.
- No `eq/ceq ... = valid` remains in `output_bs.maude`.
- No `iter-empty` / `opt-empty` derived validation labels remain.
- Source `def` clauses that previously emitted as `rl/crl`
  (`evalexprs-r1`, `evalexprss-r1`, `evalglobals-r1`, `instantiate-r0`)
  have been moved back to `eq/ceq` shape using source-derived result /
  continuation mirrors.

## Current Non-Isomorphic / Professor-Discussion Items

The main C1 isomorphism discussion items are:

1. **20 label-related `step-from-step-pure-*` shortcuts**
   - Source has `Step_pure`, `Step/pure`, and `Step/ctxt-instrs`.
   - Output also contains 20 derived label-specific executable shortcuts.
   - They are needed for current label/br suffix execution, but they are not
     direct source rules.

2. **`$infer-*` witness inference overlay**
   - Source relation premises can expose intermediate witnesses such as `TS2`.
   - The current `Judgement => valid` encoding does not return those witnesses.
   - `$infer-*` helpers are generated from source premise structure, but they
     are still source-absent execution overlay.

3. **Category / sequence sort representation gap**
   - Some source category constraints remain as `$is-spectec-*`,
     `_hasType_`, and `WellTyped`.
   - Many record/simple category guards were removed, but full typed/mixed
     sequence sorts are not yet implemented.
   - This is the main remaining gap between broad `SpectecTerminal(s)` and
     ideal source-shaped Maude sorts.

Accepted representation choices for now:

- Source-star premises lower to source-style sequence judgements such as
  `Valtype-oks` and `Val-oks`; this is accepted as source `*` lowering, not a
  random shortcut.
- `$map-*`, `$valid-*`, `$result-*`, and `$cont-*` are source-derived execution
  views for source meta-expressions / source `def` conditions. They should be
  mentioned if professor asks how `def` execution is made equational, but the
  top-level non-isomorphism discussion should focus on the three items above.

## Current Execution Audit

The latest broad generated-rule concrete audit is:

```text
artifacts/current-rule-execution-audit-20260524_213453/
```

Result:

```text
total rl/crl: 835
REDUCED: 565
STUCK: 269
STACK_OVERFLOW: 1
MAUDE_EXIT_2: 0
TIMEOUT: 0
```

Interpretation:

- `565 REDUCED`: these generated concrete commands did execute.
- `269 STUCK`: these commands did not reduce under the generated samples. This
  does not automatically mean each rule is broken; many samples lack the right
  source-valid context/store/module/type witness.
- `1 STACK_OVERFLOW`: `infer-instrs-ok-arg0-r3`, a real context-witness
  synthesis problem.

The latest focused probe matrix is:

```text
artifacts/c1-probe-matrix-20260524_225223/probe_summary.md
```

Focused failing/stuck probes:

- `step-read-br-on-cast-negative`: stack overflow.
- `step-read-br-on-cast-fail-negative`: timeout.
- `step-read-ref-test-negative`: stack overflow.
- `step-read-ref-cast-negative`: timeout.
- `steps-invoke-outer-config`: expected stuck.
- `steps-fib-config-invoke`: expected stuck.

Focused passing probes include:

- sequence index probes;
- empty and multi result type validation;
- empty-arrow instruction type validation;
- `Instr-ok/nop`, `Instr-ok/unreachable`, `Instr-ok/local.get`;
- `Instrs-ok(CONST i32 0, arrow(...))`;
- `Expr-ok-const`;
- constant-expression `Global-ok`;
- `Val-oks` empty and multi-value validation;
- `$invoke(...)` rewrites to a `Config`;
- label/br suffix search;
- br_if suffix search;
- nop suffix search;
- `steps(fib-config(i32v(5)))`.

## Known Execution Limitations

Current focused execution limitations:

1. **`infer-instrs-ok-arg0-r3`**
   - Infers a canonical context from `instr*` and an instruction type.
   - Source does not specify how to synthesize that context.
   - This is witness/context synthesis, likely C2 unless professor accepts an
     inference overlay in C1.

2. **Nonempty `$evalexprss` / `expr**`**
   - The source uses nested sequence `expr**`.
   - Current Maude representation is mostly flat `SpectecTerminals`.
   - Empty case works; nonempty flat probes are not reliably executable.

3. **Reference/cast `otherwise` negative paths**
   - Positive paths pass.
   - Latest focused negative probes still stack-overflow or timeout.
   - This is about encoding SpecTec `-- otherwise` priority/negative behavior
     in plain Maude rewriting.

4. **Source-shaped invoke / outer-frame path**
   - `$invoke(...)` itself rewrites to `Config`.
   - The named-empty-frame Fibonacci path passes.
   - Fully source-shaped outer-frame `steps(fib-config-invoke(i32v(5)))` still
     gets stuck and should be handled in init-config/frontend work.

5. **Builtin backend completeness**
   - `builtins.maude` implements the first concrete `hint(builtin)` layer for
     `$ibits`, `$inv-ibits`, `$irev`, `$lanes`, and `$inv-lanes`.
   - This is not a full SIMD/float/relaxed-numeric backend library yet.

## What To Ask Professor

Ask these before trying to make every rule execute:

1. Is C1 supposed to be a structural/isomorphic baseline with representative
   execution smokes, or must every generated rule have a source-valid concrete
   execution sample?
2. Can the 20 label-related `step-from-step-pure-*` shortcuts remain as
   temporary C1 executable debt, or must they move to a C2 execution layer?
3. Are generic witness helpers such as `$infer-*` acceptable in C1, or should
   witness synthesis be explicitly a C2 solver feature?
4. Should C1 implement typed/mixed/nested sequence sorts to remove remaining
   `$is-spectec-*` / `_hasType_` guards, or is the current broad-carrier
   representation acceptable for the baseline?
5. Should `otherwise` be encoded by source-derived decision helpers/strategies
   in C1, or deferred until an execution layer is designed?

## Recommended Next Steps

Before moving to P4/generalization:

1. Review `docs/limitation.md` with professor.
2. Decide the C1 acceptance criterion: structural baseline vs full concrete
   executable coverage.
3. If professor wants stricter C1 execution, start with the focused failures:
   reference/cast `otherwise`, `infer-instrs-ok-arg0-r3`, and nonempty
   `$evalexprss`.
4. If professor accepts benchmark-driven execution, move on to benchmark
   selection and fix paths as benchmarks require them.
5. Keep init-config/frontend/model checking separate until explicitly resumed.

## Fresh Chat Prompt

Use this when starting a new Codex chat:

```text
You are working on my Spec2Maude C1 baseline.

Please first read:
- STATUS.md
- docs/limitation.md
- docs/HowToTest.md
- artifacts/current-rule-execution-audit-20260524_213453/summary.md
- artifacts/c1-probe-matrix-20260524_225223/probe_summary.md

Current goal:
C1 is a faithful WebAssembly SpecTec-to-Maude baseline. Do not assume old
archive docs are current. Do not blindly edit translator_bs.ml.

Current non-isomorphic / professor-discussion items:
1. 20 label-related step-from-step-pure-* executable shortcuts.
2. $infer-* witness inference overlay.
3. Category / sequence representation gap: remaining $is-spectec-* and
   _hasType_ / WellTyped guards.

Current execution audit:
- 835 generated rl/crl tested by concrete audit.
- 565 REDUCED.
- 269 STUCK under generated samples.
- 1 STACK_OVERFLOW: infer-instrs-ok-arg0-r3.

Before changing code, inspect current output_bs.maude, translator_bs.ml,
docs/limitation.md, and the latest artifacts listed above.
```
