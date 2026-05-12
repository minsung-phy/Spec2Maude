# Spec2Maude Status

Updated: 2026-05-12

This is the current engineering checkpoint. Historical details are in
`meeting/session_summary.txt` and `meeting/personal_meeting_0428/`.

## Goal

Spec2Maude should translate WebAssembly 3.0 SpecTec to Maude in two stages.

1. C1 baseline: preserve the SpecTec relation structure as directly as possible.
2. C2 transformation: derive an analysis-friendly semantics from C1 for practical
   rewriting and LTL model checking.
3. Evaluation: compare C1 and C2 on rewrite/search/model-checking results.

The current priority is still C1.

## Professor Requirements For C1

C1 must preserve these SpecTec relations:

```spectec
relation Step      : config ~> config
relation Step_pure : instr* ~> instr*
relation Step_read : config ~> instr*
relation Steps     : config ~>* config
```

Required Maude shape:

```maude
op step      : Config -> StepConf [frozen (1)] .
op step-pure : InstrTerminals -> StepPureConf [frozen (1)] .
op step-read : Config -> StepReadConf [frozen (1)] .
op steps     : Config -> StepsConf [frozen (1)] .
```

Other requirements:

- `Steps` must be unary: `steps(C) => C'`, not binary `Steps(C, C') => valid`.
- Configs should print with `_ ; _`, not visible `CTORSEMICOLONA2(...)`.
- Redundant guards such as `Z : State` should be removed when Maude variable
  declarations already enforce the sort.
- Use WT/`WasmTerminal`. Do not introduce RT/`RecordTerminal`.
- Do not add `dstep`, `focused-step`, `mc`, or benchmark-specific execution
  drivers to C1.
- Do not hard-code benchmark-specific behavior in `translator_bs.ml`.

Latest 2026-05-12 professor feedback:

- Fibonacci must start from a proper WebAssembly config. The config should not
  hide execution by hand-written shortcuts.
- Check `step`, `step-pure`, `step-read`, and `steps` directly with Maude
  `search`/`rew`.
- `mc` is not the intended baseline path. The target is to run with `steps`
  directly.

## Current Implementation

Main files:

- `translator_bs.ml`: C1 translator.
- `output_bs.maude`: regenerated C1 output.
- `wasm-exec-bs.maude`: hand-written Fibonacci harness over C1.
- `translator.ml`: future C2 translator.

Implemented:

- `Step`, `Step_pure`, `Step_read`, and `Steps` are generated separately.
- `Step/pure` calls `step-pure(...)`.
- `Step/read` calls `step-read(...)`.
- `Steps/trans` has the intended unary form:

```maude
steps(C) => C''
  if step(C) => C' /\ steps(C') => C'' .
```

- Configs use `_ ; _`.
- `val^n` binders are preserved as length constraints.
- `val*` binders are guarded with `all-vals(...)` where needed.
- `Step/ctxt-instrs` uses a non-empty recursive focus to avoid the empty
  `nil` split problem.
- Optional `?` binders now generate `eps` cases generally. This is not a
  `$blocktype`-only hard-code.
- The old hard-coded executable `$invoke` footer was removed from
  `translator_bs.ml`. The only `$invoke` left in `output_bs.maude` is the one
  generated from SpecTec.
- `mc` was removed from `wasm-exec-bs.maude` as the main C1 harness path.
- SpecTec type-iteration lowering for `rollrt`/`unrollrt`/`rolldt` was fixed
  generically. The old generated form left `(i<n)` iterator variables as free
  constants such as `FREE-UNROLLRT0-I`; the new form generates finite helper
  sequences (`$rec-typevars`, `$def-typeuses`, `$idx-typeuses`) and list-lifts
  `$subst-subtype`.

Important helper policy:

- `all-vals` is a generic Maude helper for SpecTec `val*` binders.
- `$mk-frame` is a generic executable representation for SpecTec frame records.
- Generic list lifting for substitution helpers is allowed only when it encodes
  a SpecTec list-level operation. It must not be Fibonacci-specific.

## Current Fibonacci Harness

`WASM-FIB-BS` is a hand-written benchmark harness, not generated semantics.

Current `fib-config(N)` reduces to a config shaped like:

```maude
fib-store ; empty-frame ;
  N i32.const 0 i32.const 1 ref.func 0 call_ref fib-type
```

This is closer to the professor's requested call path than the old
`fib-state(N) ; fib-body` shortcut, but it is still not final evidence because
execution does not yet pass the first `call_ref`.

Current direct test result:

```maude
red in WASM-FIB-BS : fib-config(i32v(5)) .
```

Status: succeeds and shows the initial config above.

```maude
rew [1] in WASM-FIB-BS : step-read(fib-config(i32v(5))) .
```

Status: stack overflow.

Narrowed cause:

- The previous `$expanddt/$unrolldt` blocker is fixed for the fib function type.
- The current minimum failing term is now much smaller:

```maude
red in WASM-FIB-BS : CTORLEA1(CTORSA0) .
```

This stack-overflows. Because `fib-loop-body` contains
`CTORRELOPA2(CTORI32A0, CTORLEA1(CTORSA0))`, this also makes these commands
overflow:

```maude
red in WASM-FIB-BS : fib-loop-body .
red in WASM-FIB-BS : value('CODE, fib-funcinst) .
rew [1] in WASM-FIB-BS : step-read(fib-config(i32v(5))) .
```

So the current blocker is still before model checking and before `steps`: C1's
generated numeric operator constructor/membership layer is not executable for
signed operators such as `CTORLEA1(CTORSA0)`.

## Verification Done

Commands run on 2026-05-12:

```sh
dune build
dune exec ./main_bs.exe -- wasm-3.0/* > output_bs.maude
```

Both succeed.

Hard-coded `$invoke` cleanup:

```sh
rg -n '\$invoke|Executable equivalent of SpecTec invoke' translator_bs.ml output_bs.maude
```

Current result:

- no `$invoke` in `translator_bs.ml`;
- only generated SpecTec `$invoke` remains in `output_bs.maude`.

Fibonacci smoke result:

- `red fib-config(i32v(5))` succeeds.
- generic `$unrollrt/$unrolldt/$expanddt` for the fib function type succeeds.
- `red CTORLEA1(CTORSA0)` stack-overflows.
- `rew [1] step-read(fib-config(i32v(5)))` stack-overflows because the function
  body contains that signed relational operator.

## Next Work

P0. Fix generated numeric operator constructor/membership executability.

- Minimal reproducer: `red in WASM-FIB-BS : CTORLEA1(CTORSA0) .`
- Inspect generated membership/typing declarations around `binop`, `relop`,
  `vbinop`, and `vrelop`.
- The fix must be general for SpecTec numeric operator constructors.
- Do not replace the Fibonacci body with a shortcut and do not add a
  Fibonacci-specific equation.
- Do not reintroduce hard-coded `$invoke`.

P1. After the numeric constructor issue is fixed, verify relation behavior
directly.

Required evidence:

```maude
rew [1] in SPECTEC-CORE : step-pure(...) .
rew [1] in WASM-FIB-BS : step-read(fib-config(i32v(0))) .
rew [1] in WASM-FIB-BS : step(fib-config(i32v(0))) .
search [1] in WASM-FIB-BS : steps(fib-config(i32v(0))) =>* (Z:State ; i32v(0)) .
```

Then repeat for `fib(1)` and `fib(5)`.

P2. Revisit the Fibonacci initial config if needed.

- Best target: construct the config through generated SpecTec `$invoke` or
  `$instantiate`.
- The generated `$invoke` must come from SpecTec translation, not a hand-written
  footer equation.
- If `$instantiate` has bind-before-use blockers, document them separately.

P3. Only after C1 execution works, return to model checking.

- First show `steps` execution without `mc`.
- Then define the model-checking state/propositions in a way consistent with the
  professor's guidance.
- If C1 model checking times out after this, that becomes the real motivation
  for C2.

## What To Tell The Professor Now

Short version:

> The C1 translator now generates the required relation structure: `step`,
> `step-pure`, `step-read`, and unary `steps`, with `_ ; _` config syntax and no
> `mc`/`dstep` in the main path. I also removed the hand-written executable
> `$invoke` helper from the translator, so `$invoke` is now only the SpecTec
> generated one. I also fixed the earlier generic `(i<n)` type-unrolling bug:
> `$unrollrt/$unrolldt/$expanddt` now reduce for the fib function type. The
> current blocker is smaller: even `red CTORLEA1(CTORSA0)` stack-overflows, and
> the fib body contains that signed relational operator. So the next fix is the
> generated numeric operator constructor/membership layer, not model checking
> and not a Fibonacci-specific rule.
