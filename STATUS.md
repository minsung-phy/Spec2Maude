# Spec2Maude Current Handoff

Updated: 2026-05-13

This is the single file future AI agents should read first. It supersedes the
outdated parts of the previous `.codex.md`, old `STATUS.md`, and
`paper_plan.md`.

## Big Picture

Spec2Maude translates WebAssembly 3.0 SpecTec semantics into Maude.

Research structure:

1. C1: faithful relation-preserving SpecTec-to-Maude baseline.
2. C2: analysis-friendly transformation derived from C1.
3. Evaluation: rewrite/search/LTL model-checking experiments comparing C1/C2.

Current active path is still C1, but C1 now has enough execution evidence for
Fibonacci through `steps`.

## Professor Requirements

C1 must preserve the SpecTec relation structure:

```spectec
relation Step      : config ~> config
relation Step_pure : instr* ~> instr*
relation Step_read : config ~> instr*
relation Steps     : config ~>* config
```

Generated Maude must expose:

```maude
op step      : Config -> StepConf [frozen (1)] .
op step-pure : InstrTerminals -> StepPureConf [frozen (1)] .
op step-read : Config -> StepReadConf [frozen (1)] .
op steps     : Config -> StepsConf [frozen (1)] .
```

Constraints:

- `Steps` is unary: `steps(C) => C'`, not `steps(C, C')`.
- Config syntax uses `_ ; _`.
- Avoid redundant guards such as `Z : State` when Maude var declarations already
  enforce sorts.
- Do not add `mc`, `exec-step`, `dstep`, `focused-step`, hard-coded invoke, or
  benchmark-specific rules to C1.
- Do not remove `OpTerminal`, `InstrTerminals`, or `ValTerminals`.
- Do not convert `mb/cmb` globally to `$typed`.
- Do not hand-edit `output_bs.maude` as the final solution; regenerate it from
  `translator_bs.ml`.

## Important Files

- `translator_bs.ml`: C1 translator. This is the main implementation target.
- `output_bs.maude`: generated C1 output. Regenerate from `translator_bs.ml`.
- `wasm-exec-bs.maude`: current Fibonacci harness over generated C1.
- `translator.ml`, `output.maude`: older/C2 reference path; use only for
  comparison unless explicitly working on C2.
- `STATUS.md`: this file.

## Current Confirmed State

Current baseline includes:

- FNN/VECTYPE bad-token fix.
- Alias broad-membership fix:
  `cmb ( T ) : Resulttype if ( T hasType ( list ( valtype ) ) ) : WellTyped .`
  is no longer emitted.
- `step`, `step-pure`, `step-read`, `steps` wrappers exist.
- `steps` can drive Fibonacci execution without `mc`.
- Narrow refined-sort LHS fix for execution relations is implemented:
  refined syntax category variables in execution-rule LHS patterns are widened
  to `WasmTerminal`, with generated `$is-*` boolean guards from unconditional
  `mb` axioms.

## C1 Faithfulness / Isomorphism Status

Current `output_bs.maude` is intended to be the C1 relation-preserving
translation of the `wasm-3.0/*.spectec` files. It is close to SpecTec structure:

- generated relation wrappers preserve `step`, `step-pure`, `step-read`, and
  unary `steps`;
- generated syntax constructors and relation rules come from SpecTec;
- no Fibonacci-specific execution rule is emitted by `translator_bs.ml`;
- no `mc`, `exec-step`, `dstep`, or `focused-step` is emitted into C1.

Expected non-isomorphic Maude infrastructure remains. This is acceptable because
Maude needs executable encodings for some SpecTec/meta operations:

- wrapper sorts such as `StepConf`, `StepPureConf`, `StepReadConf`, `StepsConf`;
- `_ ; _` config syntax and sequence helpers;
- generic helper equations such as `all-vals`, `$cfg-state`, `$cfg-instrs`,
  `$norm-seq`, list lifting, and `$is-*` refined-category predicates;
- generated predicate helpers from unconditional membership axioms where Maude
  rewrite matching cannot use membership axioms directly.

Do not claim literal byte-for-byte isomorphism. The defensible claim is:

> C1 preserves the SpecTec relation and rule structure modulo necessary generic
> Maude executable infrastructure.

Known non-C1 part:

- `wasm-exec-bs.maude` is a harness module for Fibonacci evidence. It is not
  generated SpecTec semantics and not the final proper initial-config story.

The specific `step-read` bug fixed:

```maude
rew [1] in WASM-FIB-BS :
  step-read((((fib-store ; empty-frame).State) ;
    CTORREFNULLA1(CTORFUNCA0) CTORTHROWREFA0)) .
```

Previously did not fire because `CTORFUNCA0 : Heaptype` was only a membership
axiom, not available to rewrite matching against `HT : Heaptype`. It now returns:

```maude
result Instr: CTORTRAPA0
```

## Verified Smoke

Use `handoff` smoke files with `load ../wasm-exec-bs`, not `load wasm-exec-bs`.
There may be stale handoff copies of `wasm-exec-bs.maude`.

Latest smoke log:

```text
handoff/smoke_step_read_narrow_fix.log
```

Confirmed:

```maude
red in WASM-FIB-BS : CTORLEA1(CTORSA0) .
--- result OpTerminal: CTORLEA1(CTORSA0)

red in WASM-FIB-BS : CTORLOCALA1(CTORI32A0) .
--- result Nonfuncs: CTORLOCALA1(CTORI32A0)

red in WASM-FIB-BS : fib-func .
--- result Funccode: CTORFUNCA3(...)

red in WASM-FIB-BS : fib-config(i32v(0)) .
--- result Config: fib-store ; empty-frame ; ...

rew [1] in WASM-FIB-BS : step-pure(CTORNOPA0) .
--- result ValTerminals: eps

rew [1] in WASM-FIB-BS : step-pure(CTORUNREACHABLEA0) .
--- result Instr: CTORTRAPA0

rew [1] in WASM-FIB-BS :
  step-read((((fib-store ; empty-frame).State) ;
    CTORREFNULLA1(CTORFUNCA0) CTORTHROWREFA0)) .
--- result Instr: CTORTRAPA0

rewrite [10000] in WASM-FIB-BS : steps(fib-config(i32v(5))) .
--- result Config: fib-store ; empty-frame ; CTORCONSTA2(CTORI32A0, 5)
```

Earlier confirmed:

```maude
steps(fib-config(i32v(0))) -> CTORCONSTA2(CTORI32A0, 0)
steps(fib-config(i32v(1))) -> CTORCONSTA2(CTORI32A0, 1)
steps(fib-config(i32v(5))) -> CTORCONSTA2(CTORI32A0, 5)
```

## Current Fibonacci Harness Status

`wasm-exec-bs.maude` currently defines a harness, not a final SpecTec
instantiate/invoke initial configuration.

Current structure:

```maude
fib-store ; empty-frame ;
  N i32.const 0 i32.const 1 ref.func 0 call_ref fib-type
```

It has a real store/frame/module-instance shape:

- `fib-store`
- `fib-moduleinst`
- `fib-funcinst`
- `fib-func`
- `fib-type`
- `empty-frame`

But it still directly assembles `fib-store` and the call sequence. It does not
yet construct the initial config through generated SpecTec `$instantiate` /
`$invoke` flow.

Do not describe this as final proper initial config. The honest claim is:

> The current harness is sufficient to test generated `step`, `step-pure`,
> `step-read`, and `steps`, and `steps` executes fib(0/1/5). The next research
> task is to replace or justify the harness with a proper SpecTec initial config
> construction path.

## Next Tasks

### 1. Preserve Evidence For PPT

Already done, but keep the key logs:

- `handoff/smoke_step_read_narrow_fix.log`
- `handoff/steps_fib5_success.log`
- `handoff/steps_fib_0_1_5.log`
- `handoff/step_read_narrow_fix.diff`

For PPT, include:

- relation wrapper declarations/rules;
- `rew` evidence for `step-pure`;
- `rew` evidence for `step-read`;
- `rewrite [10000] ... steps(fib-config(i32v(5)))` result;
- optional `search` evidence if needed.

### 2. Proper SpecTec Initial Config

Goal: build Fibonacci initial config through the SpecTec instantiate/invoke
flow instead of manually assembling `fib-store ; empty-frame ; ...`.

Concrete direction:

- Inspect generated `$instantiate` and `$invoke` in `output_bs.maude`.
- Build a complete module term corresponding to the Fibonacci module.
- Provide imports/externaddr as required by `$instantiate`.
- Run `$instantiate` to allocate store/module instance.
- Then use generated `$invoke` or generated call flow to create the initial
  config.
- Avoid `fib-state ; fib-body` shortcuts.
- Avoid adding Fibonacci-specific rules to `translator_bs.ml`.

Expected risk:

- `$instantiate` may have bind-before-use or list/evaluation blockers.
- If blocked, isolate the smallest generated relation/helper that fails and
  fix translator generically.

### 3. Model Checking

Only after proper initial config work is clear:

- Define propositions over generated configs.
- Keep `mc` out of C1 semantics.
- A separate model-checking harness/module is acceptable for experiments.
- First run tiny bounded or simple LTL checks on fib(0/1/5)-style configs.
- If C1 model checking explodes after direct `steps` works, that becomes the
  motivation for C2.

### 4. C2 Later

C2 may use analysis-friendly transformations:

- heating/cooling;
- focusing;
- state-space reduction;
- canonicalization.

Do not mix C2 changes into `translator_bs.ml`.

## Cleanup Guidance

Safe to delete from repo root after preserving final logs:

- all root files starting with `__`;
- `output_bs_one_rule_diag.maude`;
- `translator_bs.ml.bak` if no longer needed.

`handoff/` is mostly scratch diagnostics. Do not keep it wholesale forever.
Before deleting it, preserve these few files elsewhere or commit equivalent
evidence. They are currently copied under
`preserved/after_step_read_narrow_fix/`:

- `handoff/smoke_step_read_narrow_fix.log`
- `handoff/step_read_narrow_fix.diff`
- `handoff/status_step_read_narrow_fix.txt`
- `handoff/steps_fib5_success.log`
- `handoff/steps_fib_0_1_5.log`
- optionally `handoff/output_bs.working_steps_alias_fix.maude`
- optionally `handoff/translator_bs.working_steps_alias_fix.ml`
- optionally `handoff/wasm-exec-bs.working_steps_alias_fix.maude`

Do not rely on stale `handoff/*.maude` harness files. If running from inside
`handoff`, use:

```maude
load ../wasm-exec-bs
```

instead of:

```maude
load wasm-exec-bs
```

## Docs Policy

Current `STATUS.md`, `paper_plan.md`, and `.codex.md` contain useful historical
context but are outdated. Future agents should prefer this file. If simplifying
the repo:

- keep `AI_HANDOFF.md`;
- either delete old docs after review or replace them with short pointers to
  `AI_HANDOFF.md`;
- do not let old claims like "`CTORLEA1(CTORSA0)` is still blocked" guide new
  work.
