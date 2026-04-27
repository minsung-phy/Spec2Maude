# Spec2Maude — 현재 상태 / 문제점 / 할일

작성일: 2026-04-19 (0421 미팅 반영: 2026-04-21, baseline 갱신: 2026-04-24, nil-split 수정: 2026-04-27)

---

## 0. 0421 미팅 반영 — 새 작업 로드맵 (최우선)

**대원칙**: "correct 먼저, 속도는 나중". 점프하지 말고 순차적으로.

### 2026-04-27 현재 한 줄 요약
- `translator_bs.ml` direct-conditional baseline은 교수님 nil-split 가설을 반영해 `fib(5)` rewrite까지 성공한다.
- 하지만 baseline `modelCheck`는 아직 실행 가능하다고 보기 어렵다. `fib(2)` reachability도 60초 안에 끝나지 않았다.
- `translator.ml` optimized 경로는 기존 fib rewrite/modelCheck 성공 경로이고, `translator_bs.ml` baseline은 correctness/reference artifact 및 differential 비교 기준으로 유지한다.

### 지금까지 한 것
- Ubuntu 환경에서 빌드/생성 경로를 복구했다.
  - `dune build`
  - `dune exec ./main_bs.exe -- wasm-3.0/* > output_bs.maude`
- Linux Maude model-checker 경로를 `../../tools/Maude-3.5.1-linux-x86_64/model-checker`로 맞췄다.
- `translator_bs.ml` baseline을 `translator.ml`과 분리했다.
  - baseline 목적: heating/cooling 없이 SpecTec `-- Step:` rule을 direct conditional `crl`로 생성.
  - `focused-step` / `step-enter` 실험은 실패 후 제거했다.
- baseline `Step/ctxt-*` 5개 rule을 direct conditional `crl`로 생성한다.
  - `Steps/trans`
  - `Step/ctxt-instrs`
  - `Step/ctxt-label`
  - `Step/ctxt-handler`
  - `Step/ctxt-frame`
- `Step/ctxt-instrs` nil-split 문제를 수정했다.
  - 기존 recursive focus: `INSTR`
  - 현재 recursive focus: `INSTR-HEAD : WasmTerminal` + `INSTR-REST : WasmTerminals`
  - 목적: recursive premise가 `eps` focus로 match되는 것을 좌항 패턴 단계에서 차단.
- baseline에서 concrete state에 대한 `Z : State` executable membership guard가 실제 step 적용을 막는 문제를 확인했다.
  - 현재 조치: `Step*` relation의 `: State` guard는 executable condition에서 제외.
  - 장기 조치: record representation에 맞는 `State` membership 생성 필요.
- `wasm-exec-bs.maude` baseline harness를 유지한다.
  - manual step override 없이 generated `output_bs.maude` direct rule을 사용.
  - fib용 `mb CTORCONSTA2(CTORI32A0, I:Int) : Val .` 추가.
- 검증된 baseline 결과:
  - `LOCAL.GET` 단일 step 정상 종료.
  - `rew [10000] in WASM-FIB-BS : steps(fib-config(i32v(5))) .`
  - 결과: 24,902 rewrites, 최종값 `CTORCONSTA2(CTORI32A0, 5)`.
- 문서 업데이트:
  - `STATUS.md`
  - `paper_plan.md`
  - `meeting/session_summary.txt`
  - `meeting/personal_meeting_0428/nil_split_stack_overflow_report.md`

### 아직 안 한 것 / 남은 문제
- baseline `modelCheck`는 아직 성공 확인 안 됐다.
  - `modelCheck(fib-config(i32v(2)), <> result-is(1))`는 60초 제한에서 미종료.
  - 이제 문제는 stack overflow가 아니라 model-checking 상태공간/proof-search 비용이다.
- `Step*`에서 제외한 `: State` guard를 더 strict하게 되살리는 작업은 아직 안 했다.
  - 그냥 다시 넣으면 concrete `fib-state(...)`가 membership에서 막혀 rule이 적용되지 않는다.
  - 해야 할 일은 raw guard 재추가가 아니라 `State` membership 생성/record typing을 정확히 고치는 것이다.
- Wasm 3.0 전체 rule catalog는 아직 미완료다.
  - 현재는 `4.3-execution.instructions.spectec`의 `-- Step:` 주요 context rule 중심으로 확인했다.
- bind-before-use warning이 남아 있다.
  - 특히 `br_on_cast-*`, `call_ref-func`, 일부 GC/array rule의 existential/result binder 처리.
- `IterPr` / `IterE` lowering은 아직 의미 보존 수준으로 완성되지 않았다.
  - load-time warning 일부는 줄였지만, sequence accumulation 의미를 일반적으로 보존하는 변환은 미완성이다.
- fib 외 benchmark는 아직 없다.
  - factorial, sum, memory/table, GC, exception benchmark가 필요하다.
- baseline과 optimized heat/cool 경로의 differential comparison harness는 아직 없다.

### 바로 다음에 해야 할 일
1. baseline modelCheck 시간을 실제로 잰다.
   - 새 스크립트: `scripts/time_baseline_modelcheck.sh`
   - 예: `scripts/time_baseline_modelcheck.sh 2 reach 600`
   - 예: `scripts/time_baseline_modelcheck.sh 5 trap 1800`
2. 교수님께 보고:
   - nil-split 가설은 맞았고, 수정 후 rewrite는 성공.
   - modelCheck는 아직 오래 걸리며, 다음 병목은 상태공간/proof-search 비용.
3. `State` membership을 정확히 생성할지, 아니면 baseline에서는 sort annotation을 executable guard에서 제외하는 정책을 유지할지 교수님과 결정.
4. `-- Step:` rule catalog를 전체 Wasm 3.0 대상으로 완성.
5. fib 외 최소 benchmark 3개를 추가.
6. 논문용으로 optimized semantics와 baseline semantics의 차이를 표로 정리.

### Step 0 (지금 당장) — conditional 전수 변환
- 모든 Step 계열 rule (`Step`, `Step-pure`, `Step-read`, 그 외 condition 있는 모든 relation rule 포함)을 **`crl` + `step` 래퍼 + conditional** 단순형으로 1:1 변환.
- 구현은 **`translator_bs.ml`** 로 분리해서 시작한다.
  - 이유: 현재 `translator.ml`의 heating/cooling 및 일반화 실험을 보존하기 위해
  - 목표: 느려도 correct 한 baseline translator 확보
- `wasm-exec.maude`의 **9개 manual override** (`step-local-set-manual` 등)를 전부 제거하고, 그래도 fib이 (느려도) 돌게 만든다.
- fib뿐 아니라 **Wasm 3.0 전체** (core + concurrency/multi-thread까지)가 이 단순형으로 돌아가는지 확인.
- 산출물은 **differential testing baseline**으로 보존 (Step 2/3 검증에 재사용).

### Step 1 — `-- Step:` rule 카탈로그
- `wasm-3.0/` 과 미래 섹션까지 포함해 **`-- Step:`이 붙은 rule** 을 우선 전수 수집.
- 패턴별 분류: LHS shape / ctxt 여부 / RHS 함수 호출 여부 / IterPr·IterE 여부.
- 현재 "4개 evaluation context + 22개 미변환"이라는 숫자 재확인.
- 필요하면 그 다음 단계에서 범위를 `-- if` 일반 rule까지 넓힌다.

### Step 2 — 일반화 (instrs heat/cool 포함)
- Value subsort 세분화: `WasmTerminals` 아래 `Val` / `NonValInstr` sort를 SpecTec 기존 정의 기반으로 강화. (VSTACK/IQUEUE 전역 리팩터는 forward-compat 리스크로 보류)
- Nondeterministic heating + **side condition** 으로 의미 있는 fragment 하나만 pick.
- label/handler/frame heat/cool은 이미 자동 생성 중이므로 유지하고 기록.

### Step 3 — translator가 reject 하도록 고도화
- "조건 만족 rule은 correct 변환 / 조건 불만족 rule은 **reject**" 까지 가는 게 최종.
- 가장 피해야 할 것: 조건 안 맞는 룰이 조용히 잘못 변환되는 경우.

### 0421 미팅 부산물 (Q1, Q2 정리)
- **Static semantics (Q1)**: 원래 dynamic이 참조 안 하면 스킵이 맞지만, 실제 `4.3-execution.instructions.spectec`이 static judgement를 참조하는 곳이 있음 → 해당 부분은 **`eq`(또는 `ceq`)** 로 변환. `mb/cmb` 까지 갈 필요 없음.
- **Rule 함수 위치 (Q2)**: 과거 노트의 "룰에 함수 금지"는 **LHS(좌항)** 한정이었음. **RHS(우항) 에 함수 호출은 허용** (오히려 SpecTec isomorphic 유지에 필요). 현재 24개는 유지.

### 진행률 표시 (Step 기준)
- Step 0: ~70% (baseline 변환기/엔트리 분리, `-- Step:` context rule 5/5 direct `crl` 생성, `focused-step` 제거, nil-split 방지용 non-empty focus 수정 완료. `fib(5)` baseline rewrite는 manual override 없이 통과. 단 baseline modelCheck는 아직 60초 내 미종료)
- Step 1: ~40% (`4.3-execution.instructions.spectec` 기준 `-- Step:` rule 5개와 generated coverage 5/5 확인. 미래 섹션/전체 rule catalog는 아직 미완)
- Step 2: 0% (instrs heat/cool off 상태)
- Step 3: 0%

### 예전 시작점 상태
- `translator.ml` 복사 및 `translator_bs.ml` 생성: 완료
- baseline 전용 엔트리 `main_bs.ml` 추가: 완료
- baseline conditional 1:1 coverage 우선 구현: 진행 중
- manual override 없이 baseline fib rewrite 확인: `fib(5)`까지 완료
- manual override 없이 baseline fib modelCheck 확인: 미완료

### 2026-04-21 baseline translator 착수
- `translator_bs.ml`, `main_bs.ml`, `dune` baseline 엔트리 분리 완료
- baseline translator의 현재 방향:
  - `-- Step:` rule은 heat/cool special-case를 끄고 direct conditional `crl`로 생성
  - non-rewrite static judgement는 `mb/cmb` 대신 `eq/ceq ... = valid`
  - dynamic rule 안의 static judgement 참조는 `... == valid`
- 실제 산출물 확인:
  - `/tmp/output_bs.maude` 생성 성공
  - `step-ctxt-instrs`, `step-ctxt-label`, `step-ctxt-handler`, `step-ctxt-frame`가 direct conditional `crl`로 생성됨
  - `heat-step-ctxt-*`, `cool-step-ctxt-*`는 baseline 산출물에 없음
- 현재 남은 baseline blocker:
  - `step-pure` schema rule에서 `PREM-Z` placeholder parse error 1건
  - `br_on_cast-*`, `call_ref-func`, 일부 GC/array rule에서 bind-before-use warning 다수
  - 즉 baseline translator 틀은 섰지만, 아직 fib baseline 검증까지는 못 갔다

---

## 1. 잘한 점 (이미 된 것)

### 번역기 (translator.ml)
- SpecTec IL AST → Maude 변환 파이프라인 동작
- TypD 처리 (AliasT/StructT/VariantT) → sort membership / hasType 기반 WellTyped
- DecD/DefD는 현재 `eq/ceq`와 `rl/crl`를 모두 사용한다.
  - 순수 함수/판정은 `eq/ceq`
  - rewrite judgement나 rewrite-dependent def는 `rl/crl`
- RelD는 현재 다음 패턴으로 정리됐다.
  1. 일반 판정 RelD (`*-ok`, `*-sub`, `Expand`, `Expand-use`) → `mb/cmb ... : ValidJudgement`
  2. rewrite judgement (`Steps`, `Eval-expr`) → `rl/crl ... => valid`
  3. Step-pure → `crl step(< Z | VALS instr IS >) => < Z | ... >`
  4. Step-read → 상태 `z` 유지하며 읽기
  5. Step → `z -> z'` 상태 변화
- `$rollrt` 하드코딩 브릿지 제거 (commit `11c341b`)

### 실행 인프라 (wasm-exec.maude)
- fib 검증용 harness와 일부 manual execution override 유지
- 현재 auto-generated eval-context는 `output.maude`의 `label/frame/handler` heating/cooling이 기준
- `instrs` context와 일부 bootstrap은 아직 `wasm-exec.maude` manual rule이 남아 있음
- WASM-FIB 모듈 (fib-config, fib-body, fib-loop-body)
- 모델체킹 설정 (`result-is`, `trap-seen` atomic props)
- `modelCheck(fib-config(i32v(5)), <> result-is(5))` 실행 자체는 가능 (결과는 아래 문제점 참조)

### 산출물
- `output.maude` 7,200여 줄 자동 생성
- 랩미팅용 패턴 설명 문서 `labmeeting.md` 작성

---

## 2. 현재 문제점

### 2026-04-20 문서 정리
- 현재 translator/output/wasm-exec 상태에 맞춰 문서를 갱신했다.
  - `docs/translate_example.spectec`
  - `rule_0420.md`
  - `rules_0420.md`
  - `evaluation_context.md`
  - `session_summary.txt`
- 이번 문서 정리의 기준:
  - `prove/proved/ProofState/Proved`는 현재 생성물에서 제거된 상태
  - `*-ok`, `*-sub`, `Expand`, `Expand-use`는 `mb/cmb`
  - `Steps`, `Eval-expr`, rewrite-dependent `DecD/DefD`는 `rl/crl`
  - evaluation context는 현재 `label/handler/frame`만 `output.maude`에서 auto heat/cool 생성
  - `instrs` context는 아직 auto heat/cool 미생성이고 `wasm-exec.maude` 수동 rule이 남아 있음

### ✅ P0-0. Step rule rl/crl 전환 완료
- 통합 전략은 유지했다. 기준은 `translator.ml`이고, `translator_0417.ml`에서 **Step rl/crl 생성 경로**와 **context heating/cooling 경로**만 선택 이식했다.
- 현재 `translator.ml`은 `Step` / `Step-pure` / `Step-read`를 `rl/crl`로 생성한다.
- `step`은 이제 `op step : ExecConf -> ExecConf [frozen (1)] .` 로 생성되어 top-most 1-step 통제가 작동한다.
- 실행을 막던 translator 쪽 병목도 함께 수정했다.
  - `Idx` 계열 `Int` bridge overload 제거 (`$local/$global/... : State Int -> ...` 제거)
  - `Nat < Idx/Localidx/...` subsort 추가
  - 잘못된 generic `heat-step-ctxt-instrs` / `cool-step-ctxt-instrs` 제거
- 유지한 제약:
  - RelD Bool 반환 체계로 회귀 안 함
  - type-ok 체계로 전체 전환 안 함
  - rollrt 특수 브리지 재도입 안 함

### ✅ P0-A. fib rewrite / modelCheck 통과
- 검증 결과:
  - `rewrite [10000] in WASM-FIB : steps(fib-config(i32v(5))) .`
    - 종료
    - 최종 결과 핵심: `CTORCONSTA2(CTORI32A0, 5)`
  - `red in WASM-FIB-PROPS : modelCheck(fib-config(i32v(5)), <> result-is(5)) .`
    - `result Bool: true`
  - `red in WASM-FIB-PROPS : modelCheck(fib-config(i32v(5)), [] ~ trap-seen) .`
    - `result Bool: true`
- 디버깅 과정에서 실제 원인으로 확인된 translator 문제:
  - `$local` lookup이 값으로 끝나지 않고 `index(..., CTORWIDXA1(...))`에 남는 문제
  - `step` 내부에서 `exec-step`가 다시 발화해 `step(step(...))`가 생기는 문제
  - generic `instrs` heating이 `CONST BRIF` 같은 이미 redex인 조각을 잘못 분해하는 문제
- 위 3개는 모두 `translator.ml` 수정 후 해결됐다.
- 추가 확인:
  - `rewrite [10000] in WASM-FIB : steps(fib-config(i32v(0))) .` → `CTORCONSTA2(CTORI32A0, 0)`
  - `rewrite [10000] in WASM-FIB : steps(fib-config(i32v(1))) .` → `CTORCONSTA2(CTORI32A0, 1)`
  - `rewrite [10000] in WASM-FIB : steps(fib-config(i32v(2))) .` → `CTORCONSTA2(CTORI32A0, 1)`
  - `rewrite [10000] in WASM-FIB : steps(fib-config(i32v(3))) .` → `CTORCONSTA2(CTORI32A0, 2)`
  - `rewrite [10000] in WASM-FIB : steps(fib-config(i32v(4))) .` → `CTORCONSTA2(CTORI32A0, 3)`
  - `rewrite [10000] in WASM-FIB : steps(fib-config(i32v(5))) .` → `CTORCONSTA2(CTORI32A0, 5)`

### P0-B. V128 stack overflow (WIP 브랜치에서 발견)
- 위 P0-A 작업 중, translator의 `type_guard` regex 버그 수정 → `cmb T : V128 if true` 가 `cmb T : V128 if (T hasType (vN(128))) : WellTyped` 로 정상화됨
- 그러나 `output.maude` 2275줄의 `mb (T hasType (vN(N))) : WellTyped .` 가 **무조건** 매칭 → 모든 term이 V128로 취급 → `red step(...)` 시 Maude stack overflow
- 해결 미완. `wip/p0-v128-overflow` 브랜치에 WIP로 저장됨

### P0-C. Maude 경고 다수
- Warning: membership axioms are not guaranteed to work correctly for iterated/associative symbols
  (`s_`, `_+_`, `_*_`, `gcd`, `lcm`, `min`, `max`, `_xor_`, `_&_`, `_|_`, `__`)
- Advisory: `$lsizenn`, `$vsize`, `CTORSA0` 등의 assignment condition에서 LHS 변수가 이미 bound
- 현재는 동작에 직접 영향 없어 보임 (경고만), 하지만 근본적 해결 필요
- 2026-04-19 현재 최신 `maude -no-banner wasm-exec.maude` 로딩 로그 기준 분류:
  - `used before it is bound in membership axiom`: 0건
    - `VariantT` numeric range case(`byte`, `uN`, `sN`)의 binder 연결을 고친 뒤 사라졌다.
  - `used before it is bound in equation`: 1건
    - 현재 남은 1건은 translator 산출물이 아니라 `wasm-exec.maude`의 `result-neg` (`MC-I`)이다.
    - translator 산출물 쪽 `$subst-all-*` 10건은 DecD에서 RHS-only vm 변수를 free constant namespace로 분리한 뒤 사라졌다.
  - `used before it is bound in rule`: 0건
    - 이전의 `STEP-READ-LOAD-NUM-VAL41-C`, `STEP-READ-LOAD-PACK-VAL43-C`, `STEP-READ-VLOAD-SPLAT-VAL49-J`, `STEP-READ-VLOAD-ZERO-VAL51-J`, `STEP-READ-VLOAD-LANE-VAL53-K`는 `IfPr` fallback에서 `decompose_eq_expr`를 다시 적용하도록 고친 뒤 사라졌다.
    - `STEP-READ-VLOAD-PACK-VAL47-J`도 현재 재생성본에서는 load-time bind-before-use warning으로는 더 이상 나타나지 않는다.
    - 현재 산출물에서는 `STEP-READ-VLOAD-PACK-VAL47-J`가 `WasmTerminals` sequence binder로 선언된다.
    - 판정: load-time warning은 해소됐지만, 아래 IterPr/IterE lowering 공백은 그대로 남아 있다.
  - `multiple distinct parses for statement`: 35건
    - 예: `uN(N)`/`fNmag(N)` 타입 판정, `$canon`, `Memtype-ok`, `Tabletype-ok`, 일부 `step-read-*`
    - 성격: 괄호/우선순위/assoc 선언 상의 모호성
    - 판정: parse ambiguity 경고. 현재 fib 실행은 통과
  - assignment-condition advisory: 8건
    - 예: `$lsizenn(JNN) := 8`, `CTORSA0 := SX1`, `$vsize(VECTYPE) quo 2 := SZ1 * M1`
    - 성격: 이미 bound된 항에 assignment condition을 사용
    - 판정: 성능/가독성 문제. 현재 치명도 낮음
  - import 중복 advisory: 4건
    - `pretype.maude`의 `_[_<-_]` 중복 import 3건, `State` sort 중복 import 1건
    - 성격: 모듈 import 구조 문제
    - 판정: 현재 실행 blocker 아님
- 추가 메모:
  - `wasm-exec.maude`에도 `result-neg` 판정식에서 `MC-I`가 condition 뒤에 나오는 `used before it is bound in equation` 1건이 있다.
  - 위 집계는 현재 산출물 기준 "로딩 시 관찰된 건수"다. rewrite 시점 추가 경고까지 합친 총량은 별도 재집계가 필요하다.
- translator 경로 추적 결과:
  - `translate_decd`는 최종 선언 집계에서 `vm_vars`를 무조건 `all_bound`에 넣는다.
    - 코드 위치: `translator.ml`의 `translate_decd`, `all_bound := ... @ bound @ vm_vars`
    - 결과: 실제로는 RHS/조건식에서만 쓰이는 변수도 Maude `var`로 선언되어 `$subst-all-*`, `$rollrt/$unrollrt/$rolldt`, `$allocmodule`, `$invoke` 같은 eq/ceq에서 `used before it is bound in equation` 경고가 난다.
  - `translate_reld`도 동일하게 `vm_vars`를 무조건 `all_bound`에 넣는다.
    - 코드 위치: `translator.ml`의 `translate_reld`, `all_bound := ... @ bound @ vm_vars`
    - 결과: `Subtype-ok`, `Instr-ok` 등 많은 membership axiom에서 premise 안에서만 등장하는 변수가 조기 `var` 선언된다.
  - `translate_prem` / `translate_reld`는 일반 `RulePr`를 `... : ValidJudgement` witness로만 다루고, premise 결과가 새 변수를 바인드하는 경우를 표현하지 못한다.
    - 결과: `Expand(...)`, `Expand-use(...)` 같은 premise가 `T1`, `T2`, `COMPTYPEQ`류 출력을 만들어야 하는 규칙에서 existential-like 변수가 바인딩되지 않은 채 condition에 남는다.
    - 현재 `Step` 계열은 별도 `translate_step_reld` 경로라 이 문제에서 제외된다.
  - 2026-04-19 추가 실험:
    - `translate_decd` / `translate_reld`에서 `vm_vars`를 무조건 `all_bound`에 넣지 않도록 줄였고, build/regenerate/fib 재검증까지 완료했다.
    - 결과: fib 실행/모델체킹은 그대로 통과했지만, `used before it is bound` 경고의 주된 묶음은 거의 줄지 않았다.
    - 해석: 핵심 원인은 "변수 선언 과다"뿐 아니라 TypD/DecD 내부에서 fresh-like 출력을 바인드하는 방식 자체에도 있다.
    - IL 디버그로 `bit`, `byte`, `uN`, `sN`를 확인한 결과 이들은 `AliasT`가 아니라 `VariantT`였다.
    - 따라서 `Byte/uN` 경고의 직접 원인은 `AliasT`가 아니라 `VariantT`의 anonymous numeric range case 처리 쪽이었다.
    - `VariantT`의 `TupT` typbind에서 field expression binder를 parameter로 회수하도록 고쳤고, `byte/uN/sN` membership warning은 이 수정으로 해결됐다.
    - `translate_step_reld`의 condition 조립 순서를 `prem := ...`가 `all-vals(...)`보다 앞서 오게 바꿨고, 일부 `step-read` bind-before-use 경고를 제거했다.
    - 일반 `IfPr` fallback에서도 `decompose_eq_expr`를 다시 적용하게 바꿨고, load/vload 계열 `step-read` 경고 6건 중 5건이 사라졌다.
    - `IterPr`는 premise 분해 단계에서 재귀적으로 따라가도록 조정했고, 현재 재생성본에서는 `vload-pack-val`의 `J`가 `WasmTerminals` sequence binder로 선언된다.
    - 다만 이것은 load-time warning을 없앤 수준이다. `IterPr`/`IterE`의 의미 자체를 보존하는 lowering은 아직 없다.
    - `translate_decd`에서는 RHS에만 남는 vm 변수를 `FREE-*` constant namespace로 분리해 `$subst-all-*` equation 경고를 제거했다.
  - 남은 핵심 translator 공백:
    - 원본 SpecTec rule: `wasm-3.0/4.3-execution.instructions.spectec`의 `Step_read/vload-pack-val`
    - 핵심 premise: `(if $ibytes_(M, j) = ...)^(k<K)` 와 `if c = $inv_lanes_(Jnn X K, $extend__(..., j)^K)`
    - 디버그로 확인한 실제 IL 형태:
      - binders: `z, at, i, M, K, sx, x, ao, c, j*, k*, Jnn`
      - first prem: `(if $ibytes_(M, j) = ...)^(k<K){j <- j*, k <- k*}`
      - second prem: `if c = $inv_lanes_(Jnn X K, $extend__(..., j)^K{j <- j*}) /\ ...`
    - 현재 output:
      - 첫 premise는 `STEP-READ-VLOAD-PACK-VAL47-J : WasmTerminals` 위에 `$ibytes(..., STEP-READ-VLOAD-PACK-VAL47-J) := slice(...)`로 내려간다.
      - 둘째 premise는 여전히 `$inv-lanes(..., $extend(..., STEP-READ-VLOAD-PACK-VAL47-J))`처럼 반복 body를 scalar-like 호출로 잃는다.
    - 해석:
      - load-time bind-before-use warning은 사라졌지만, `IterPr`의 sequence accumulation과 `IterE(non-VarE)`의 반복 body lowering은 아직 구현되지 않았다.
      - 같은 구조는 vector helper 쪽에서도 보인다.
        - 예: `output.maude`의 `$ivrelop`, `$ivextunop` 등은 `FREE-...-CSTAR == $extend(..., C1)`처럼 starred body가 scalar 호출로 평탄화되어 있다.
    - 판정: 남은 우선순위는 "warning 제거"보다 "IterPr/IterE 의미 보존 lowering"이다.

### P1. Eval-context 자동 생성 부분 완료
- `translator.ml`이 SpecTec `RulePr` premise에서 label/frame/handler context용 heat/cool을 자동 생성한다.
- 현재 유지되는 자동 생성 경로:
  - label context
  - frame context
  - handler context
- 제거한 자동 생성 경로:
  - generic `instrs` context heat/cool
  - 이유: fib 실행에서 잘못된 분해를 일으켜 `restore-instrs(step(...))`에 멈췄고, 이는 의미 보존보다 회귀를 만들었다.
- `wasm-exec.maude`의 수동 context rule 일부는 여전히 남아 있다. 완전 제거는 후속 정리 항목이다.
- 2026-04-19 추가 정리:
  - `wasm-exec.maude`에 중복으로 남아 있던 `is-val`, `all-vals`, `is-trap` helper 정의는 제거했다.
  - 이 helper들은 이제 `output.maude` 생성물만 사용한다.
  - `LOCAL.GET/GLOBAL.GET/CALL`, `LOCAL.SET/TEE`, `BLOCK/LOOP`, `exec-label/frame/handler`, `steps`, `exec-step`, `restore-*`는 단순 중복이 아니라 harness/override 역할이라 유지했다.
  - 제거 후에도 `steps(fib-config(i32v(5)))`, `modelCheck(..., <> result-is(5))`, `modelCheck(..., [] ~ trap-seen)`은 그대로 통과했다.
  - 2026-04-19 추가 분해:
    - `restore-label/restore-frame/restore-handler`를 `wasm-exec.maude`에서 다시 선언하던 중복은 제거했다.
    - 그 뒤에도 `step(< Z | CTORLABELLBRACERBRACEA3(..., eps, exec-loop(...)) IS >)`는 `restore-label(...)`에서 멈춘다.
    - `heat-step-ctxt-label` 자체는 실제로 발화한다.
    - 하지만 non-trivial case의 `restore-label(< Z | CTORLABELLBRACERBRACEA3(...) >, 0, eps, IS)`는 generated `cool-step-ctxt-label`로 다시 조립되지 않는다.
    - trivial case인 `restore-label(< Z | eps >, 0, eps, eps)`는 정상적으로 cooling 된다.
    - `exec-loop`를 제거하고 raw `CTORLOOPA2(...)`를 넣어도 block/label 경로는 여전히 정지한다.
    - 현재 판정: 핵심 blocker는 harness helper 중복 자체보다, generated label/frame heating-cooling과 실제 step rule의 조합 방식이다.
    - 2026-04-19 추가 확인:
      - `output.maude`의 context wrapper ctor 선언을 concrete sort로 교정했다.
        - `CTORLABELLBRACERBRACEA3 : N WasmTerminals WasmTerminals -> Instr`
        - `CTORFRAMELBRACERBRACEA3 : N Frame WasmTerminals -> Instr`
        - `CTORHANDLERLBRACERBRACEA3 : N Catch WasmTerminals -> Instr`
      - 이 변경 후 실제 확인:
        - `CTORLABELLBRACERBRACEA3(0, eps, fib-loop-body) :: Instr` → `true`
        - 따라서 이전의 “wrapper generic ctor 때문에 label 자체가 well-sorted하지 않다” 문제는 일부 해결됐다.
      - 그러나 fib deadlock은 계속 남아 있다.
        - `rewrite [10000] in WASM-FIB : steps(fib-config(i32v(5))) .`
          → `steps(restore-label(< ... | CTORLABELLBRACERBRACEA3(0, CTORLOOPA2(...), fib-loop-body) >, 0, eps, CTORLOCALGETA1(1)))`
        - `modelCheck(fib-config(i32v(5)), <> result-is(5))`
          → counterexample / deadlock
      - 현재 가장 구체적인 잔여 원인:
        - generated `cool-step-ctxt-label`은
          `restore-label(< Z | IS >, N, INSTR0, IS-REST) => < Z | label(N, INSTR0, IS) IS-REST >`
          형태인데,
        - 실제 deadlock term은
          `restore-label(< Z | CTORLABELLBRACERBRACEA3(0, CTORLOOPA2(...), fib-loop-body) >, 0, eps, CTORLOCALGETA1(1))`
          또는 `restore-label(step(< Z | exec-loop(...) >), 0, eps, CTORLOCALGETA1(1))`
          로 남아 있다.
        - 즉 현재는 “label wrapper sort”보다는
          1. manual `step-read-block-manual` / `step-read-exec-loop`가 넣는 `eps` / loop-body shape
          2. generated heat/cool이 기대하는 `restore-label` argument shape
          의 불일치가 더 유력하다.
      - 추가 관찰:
        - `wasm-exec.maude`의 `fib-frame`, `fib-state`를 `Frame`, `State`로 선언했지만,
          실제 `fib-frame(i32v(5)) :: Frame`, `fib-state(i32v(5)) :: State`는 여전히 `false`였다.
        - 따라서 harness 쪽 record sort membership도 별도로 다시 확인해야 한다.
      - 2026-04-19 추가 분해:
        - `wasm-exec.maude`에서 `exec-loop`와 수동 `step-read-exec-loop`를 제거하고, fib harness를
          `CTORBLOCKA2(void-bt, CTORLOOPA2(void-bt, fib-loop-body))`
          형태로 바꿔 generated `step-read-block/loop`만 쓰게 해봤다.
        - 이 경우 결과:
          - `rewrite [10000] in WASM-FIB : steps(fib-config(i32v(5))) .`
            → 초기 상태에서 `steps(step(< ... | BLOCK(LOOP(...)) LOCAL.GET(1) >))`로 정지
          - `modelCheck(..., <> result-is(5))`
            → 초기 상태 deadlock counterexample
        - 직접 확인:
          - `CTORBLOCKA2(void-bt, CTORLOOPA2(void-bt, fib-loop-body)) :: Instr` → `false`
          - `CTORLOOPA2(void-bt, fib-loop-body) :: Instr` → `false`
          - `fib-state(i32v(5)) :: State` → `false`
        - 판정:
          - generated `step-read-block/loop`의 sort guard가 현재 fib harness term과 맞지 않아, manual block/loop bridge 없이 바로는 진행되지 않는다.
        - 그래서 `exec-loop`는 계속 제거한 채, 수동 `step-read-block-manual` / `step-read-loop-manual`만 복원해 다시 검증했다.
        - 그 결과:
          - `steps(fib-config(i32v(5)))`는 다시 안쪽까지 진행하지만,
            `restore-label(restore-label(step(< ... >), 0, loop, eps), 0, eps, local.get(1))`
            형태의 nested label/restore-label에서 deadlock으로 돌아온다.
          - `modelCheck(..., [] ~ trap-seen)`는 여전히 `true`
        - 현재 결론:
          - 핵심 blocker는 `exec-loop` 자체가 아니다.
          - `manual block/loop bootstrap + generated label heat/cool` 조합에서 nested label이 다시 heat/cool되며 deadlock이 생긴다.
          - 다음 우선 조사 대상은 `translator.ml`의 `needs-label-ctxt` / generated label heat/cool guard다.
      - 2026-04-19 추가 실험:
        - `translator.ml`의 auto-added helper `needs-label-ctxt`에
          `CTORLABELLBRACERBRACEA3(...)` head를 `true`로 보는 규칙을 추가했다.
        - `dune build` 성공, `output.maude` 재생성 성공.
        - 재검증 결과:
          - `rewrite [10000] in WASM-FIB : steps(fib-config(i32v(5))) .`
            → 여전히
            `restore-label(restore-label(step(< ... >), 0, loop, eps), 0, eps, CTORLOCALGETA1(1))`
            형태 deadlock
          - `red in WASM-FIB-PROPS : modelCheck(fib-config(i32v(5)), <> result-is(5)) .`
            → 여전히 counterexample / deadlock
          - `red in WASM-FIB-PROPS : modelCheck(fib-config(i32v(5)), [] ~ trap-seen) .`
            → `true`
        - 직접 확인:
          - `red in WASM-FIB : needs-label-ctxt(CTORLABELLBRACERBRACEA3(...)) .`
            → 여전히 `false`
        - 판정:
          - 단순 helper case 추가만으로는 outer label reheating을 막지 못했다.
          - 현재 더 유력한 원인은
            1. `needs-label-ctxt` 식 자체가 assoc `WasmTerminals`에서 wrapper-head를 기대대로 못 잡는 문제
            2. 또는 helper가 아니라 generated `heat-step-ctxt-label` 조건/shape 자체 문제
          - 다음 작업은 `needs-label-ctxt`를 wrapper-head 전용 detector로 다시 설계하거나, label heat rule에서 outer-label-on-label case를 직접 제외하는 것이다.
      - 2026-04-19 추가 실험 2:
        - `needs-label-ctxt`와 별도로 `starts-label-ctxt : WasmTerminals -> Bool` helper를 추가했다.
        - `heat-step-ctxt-label`은 이제
          `needs-label-ctxt(inner) = false /\ starts-label-ctxt(inner) = false`
          를 둘 다 요구한다.
        - `dune build` 성공, `output.maude` 재생성 성공 (`output.maude` 9268줄).
        - 직접 확인:
          - `red in WASM-FIB : starts-label-ctxt(CTORLABELLBRACERBRACEA3(...)) .`
            → 여전히 `false`
        - 재검증 결과:
          - `rewrite [10000] in WASM-FIB : steps(fib-config(i32v(5))) .`
            → 여전히 nested `restore-label` deadlock
          - `modelCheck(fib-config(i32v(5)), [] ~ trap-seen)` → `true`
          - `modelCheck(fib-config(i32v(5)), <> result-is(5))`
            → 성공으로 확인되지 않음, deadlock trace 지속
        - 현재 판정:
          - helper 이름이나 rule 추가 수의 문제가 아니라,
            현재 helper 스타일의 패턴 매칭이 assoc `WasmTerminals` 위에서
            wrapper-head를 기대대로 식별하지 못한다.
          - 따라서 다음 후보는
            1. helper 기반 우회를 버리고 `heat-step-ctxt-label` rule shape 자체를 다시 설계하거나
            2. manual block/loop bootstrap이 생성하는 label nesting 방식을 바꾸는 것이다.
      - 2026-04-19 추가 실험 3 (Claude Opus 4.7 세션 후속):
        - nested label deadlock을 동일하게 재현했다.
          - `rewrite [10000] in WASM-FIB : steps(fib-config(i32v(5))) .`
            → `steps(restore-label(restore-label(step(< ... >), 0, loop, eps), 0, eps, ...))` 형태 잔류
          - `red in WASM-FIB-PROPS : modelCheck(fib-config(i32v(5)), <> result-is(5)) .`
            → `counterexample(... deadlock)`
          - `red in WASM-FIB-PROPS : modelCheck(fib-config(i32v(5)), [] ~ trap-seen) .`
            → `true`
        - helper/guard 경로를 재점검한 뒤, 의미론 정합성 기준으로 최종 롤백했다.
          - 제거: `starts-label-ctxt` helper 및 heat guard 연동
          - 제거: `needs-label-ctxt(CTORLABELLBRACERBRACEA3(...)) = true` 케이스
          - 복원: `heat-step-ctxt-label` guard를 `needs-label-ctxt(inner) = false` 단독 조건으로 유지
        - probe 확인:
          - `needs-label-ctxt(CTORBRA1(0)) = true`
          - `needs-label-ctxt(CTORLABELLBRACERBRACEA3(0, eps, CTORBRA1(0))) = false`
        - 결론:
          - (해결됨) `needs-label-ctxt`는 completed control-flow (`VAL* + BR/RETURN/RETURN-CALL-REF/THROW-REF`) 차단 용도로 사용하는 것이 맞으며, 중첩된 라벨 안으로 정상적으로 가열(heating)되도록 재귀 검사를 비활성화했다.
          - (해결됨) 가장 결정적인 문제였던 "가열된 제어 흐름 명령어의 고립(Deadlock)" 문제는, 제어 흐름 명령어 발생 시 강제로 껍데기를 다시 씌워주는 **제어 전용 냉각(Control Cooling) 규칙**(`cool-step-ctxt-*-control`)을 번역기가 자동 생성하게 만들어 해결했다.
          - **현재 `fib(0)` ~ `fib(5)` 모두 `modelCheck` 및 `rewrite` 완벽 통과.** (Deadlock 완전 해소)

### P2. 범위 검증 미실시
- fib 외 다른 예제 (factorial, 재귀 call, memory op 등) 미테스트
- translator가 SpecTec rule **몇 개** 중 **몇 개** 번역하는지 수치 미측정
- fib 결과는 `fib(0)` ~ `fib(5)`까지 확인했지만, 아직 fib 외 예제로 범위를 넓히지는 못했다

---

## 3. 할일 리스트 (우선순위순)

### 최우선 (우선순위 변경, 2026-04-19)
- [ ] **교수님 요구사항 재정렬: SpecTec Rule ↔ Maude Rule isomorphic 구조 재검토**
  - meeting 근거 재확인:
    - 실행/전이 의미의 **Rule** 은 `eq/ceq`가 아니라 `rl/crl`이어야 함
    - evaluation context (`label/frame/instrs/handler`) 는 **heating/cooling rule** 로 분리해야 함
  - 현재 상태 점검 대상:
    - `translator.ml`의 일반 `RelD(rule)` 경로가 아직 `cmb ... : ValidJudgement` / `eq/ceq` 중심이라, “Rule이면 무조건 rl/crl” 요구와 어긋나는 부분이 있는지 다시 분리해야 함
    - `wasm-exec.maude`에는 여전히 `LOCAL.GET/GLOBAL.GET/CALL`, `LOCAL.SET/TEE`, `BLOCK/LOOP` 등 수동 `ceq` override가 남아 있어 isomorphic 구조를 깨고 있음
    - 자동 생성된 eval-context는 현재 `label/frame/handler`까지만 있고, `instrs`는 자동 heating/cooling을 꺼 둔 상태라 `docs/rule.maude`의 4-4 구성과 아직 다름
  - 바로 다음 작업:
    - `meeting/*`, `docs/rule.maude`, `translator.ml`, `wasm-exec.maude`를 기준으로
      1. 현재 무엇이 `rl/crl`이고 무엇이 아직 `eq/ceq`인지 표로 분리
      2. “허용되는 eq/mb/cmb”와 “Rule이라서 rl/crl로 가야 하는 것”을 다시 경계 설정
      3. `wasm-exec.maude` 수동 override를 어떤 순서로 translator 쪽으로 흡수/치환할지 계획 수립
- [x] 1차 이행:
  - `translate_reld`를 `mb/cmb ... : ValidJudgement`에서 `rl/crl prove(Rel(...)) => proved` 경로로 전환했다.
  - `Step/Step-pure/Step-read` premise는 relation rule 안에서 직접 rewrite condition(`step(<...>) => <...>`)으로 내려가게 했다.
  - 일반 relation premise는 `prove(Rel(...)) : Proved` witness를 사용하도록 바꿨다.
  - `output.maude` 기준 확인:
    - `Numtype-ok`, `Val-ok`, `Steps`, `Eval-expr` 등이 이제 `prove(...)` 기반 `rl/crl`로 생성된다.
    - `Steps/trans`처럼 조건에 실제 `step(...) => ...`가 들어가는 rule도 생성된다.
  - parse 안정화:
    - `prove(...) : Proved` bridge가 rewrite 조건을 포함할 때 생기던 parse error는, 그런 case에서는 bridge를 생략하도록 해소했다.
  - 현재 남은 불일치:
    - `wasm-exec.maude`에는 여전히 `LOCAL.GET/GLOBAL.GET/CALL`, `LOCAL.SET/TEE`, `BLOCK/LOOP` 등 수동 `ceq` override가 남아 있다.
    - `instrs` evaluation context는 아직 docs/rule.maude식 자동 heating/cooling이 아니라 수동 우회 상태다.
  - 재검증:
    - `rewrite [10000] in WASM-FIB : steps(fib-config(i32v(5))) .` → 최종 `i32 5`
    - `red in WASM-FIB-PROPS : modelCheck(fib-config(i32v(5)), <> result-is(5)) .` → `true`
    - `red in WASM-FIB-PROPS : modelCheck(fib-config(i32v(5)), [] ~ trap-seen) .` → `true`
  - 2026-04-19 현재 작업 상태:
    - 위 fib 통과 상태는 `wasm-exec.maude`를 `rl/crl + heating/cooling` 구조로 정리하는 과정에서 다시 깨진 상태다.
    - 현재 실제 실행 결과:
      - `rewrite [10000] in WASM-FIB : steps(fib-config(i32v(5))) .`
        → `steps(< ... | CTORLABELLBRACERBRACEA3(0, eps, exec-loop(...)) CTORLOCALGETA1(1) >)`에서 정지
      - `red in WASM-FIB-PROPS : modelCheck(fib-config(i32v(5)), <> result-is(5)) .`
        → counterexample / deadlock
      - `red in WASM-FIB-PROPS : modelCheck(fib-config(i32v(5)), [] ~ trap-seen) .`
        → `true`
    - 따라서 이 항목은 "과거 한때 통과했던 상태 기록"이고, 현재 main 작업 상태의 기준선은 아니다.

### 보류 기록 (이전 최우선 작업 저장)
- [ ] `IterPr` / `IterE(non-VarE)` 의미 보존 lowering
  - 현재 load-time bind-before-use warning 자체는 사라졌지만, 반복 sequence를 scalar처럼 평탄화하는 문제가 남아 있다
  - 시작점:
    - `translator.ml`의 `translate_exp` `IterE` 경로
    - `translate_prem` / `prem_items_of_prem`의 `IterPr` 경로
  - 목표:
    - `vload-pack-val`과 vector helper 계열에서 `j^K`, `$extend(...)*`, `$setproduct(...)*` 같은 반복 body를 sequence-aware 하게 lowering
    - 전역 `binder_to_var_map` alias 규칙은 건드리지 않고 helper 기반 lowering 설계
### 즉시 (다음 세션 1회)
- [x] **일반 판정 규칙 정리**: 타입 판정류(`Numtype-ok`, `Val-ok`, `Memtype-ok` 등)는 `prove(...) => proved` 대신 `mb/cmb`로 전환 완료
  - `Step` / `Step-pure` / `Step-read`는 계속 `rl/crl`
- [x] **`prove` 레이어 최소화 2단계**: `*-sub`, `Expand`, `Expand-use`, `Eval-expr`를 `mb/cmb`로 복귀
  - 현재 `output.maude` 기준 `prove(...)`가 남아 있는 relation은 `Steps`뿐이다.
  - 이유:
    - `Steps/trans`의 조건에는 `step(<...>) => <...>` rewrite condition이 직접 들어간다.
    - 이걸 `cmb Steps(...) : ValidJudgement if ...`로 내리면 Maude가 `didn't expect token =>` / `no parse for statement`를 낸다.
    - 따라서 `Steps`만 예외적으로 `crl prove(Steps(...)) => proved` + `cmb prove(Steps(...)) : Proved`를 유지한다.
  - `translate_prem`도 같이 수정해서:
    - `RulePr Steps`는 `prove ( Steps(...) ) : Proved`
    - 나머지 non-step relation premise는 `... : ValidJudgement`
  - 재생성 결과 확인:
    - `prove_relations [('Steps', 5)]`
    - `Expand`, `Expand-use`, `Eval-expr`, `*-sub`는 `cmb ... : ValidJudgement`
  - 재검증:
    - `rewrite [10000] in WASM-FIB : steps(fib-config(i32v(5))) .` → 최종 `i32 5`
    - `red in WASM-FIB-PROPS : modelCheck(fib-config(i32v(5)), <> result-is(5)) .` → `true`
    - `red in WASM-FIB-PROPS : modelCheck(fib-config(i32v(5)), [] ~ trap-seen) .` → `true`
- [ ] **`prove` 완전 제거**
  - 2026-04-20 실험:
    - `Steps`를 `crl Steps(...) => valid`로 바꾸고 `prove/proved/Proved/ProofState`를 생성물에서 0개까지 제거하는 데는 성공했다.
    - 실제 생성물 확인:
      - `prove 0`
      - `proved 0`
      - `Proved 0`
      - `ProofState 0`
  - 하지만 현재는 완료로 판정할 수 없다.
    - `output.maude`에서 아래 parse warning이 새로 생긴다.
      - `ceq $evalexprs ... if Eval-expr(...) => valid /\ ...`
      - `ceq $evalglobals ... if Eval-expr(...) => valid /\ ...`
    - 즉 `DecD/DefD`의 `ceq` 조건 안에는 rewrite condition(`=> valid`)을 그대로 넣을 수 없다.
    - 같은 이유로
      - `Steps`를 membership으로 두면 `Steps/trans`의 `step(<...>) => <...>` 때문에 깨지고
      - `Eval-expr`를 rewrite relation으로 두면 이를 참조하는 `$evalexprs/$evalglobals`가 깨진다.
  - 현재 판정:
    - `prove` 완전 제거는 **방향만 확인됐고, translator 전체로는 아직 미완료**다.
    - 근본 해결에는 아래 중 하나가 필요하다.
      1. `DecD/DefD`에서 rewrite relation premise를 직접 쓰지 않도록 별도 lowering 경로 설계
      2. `$evalexprs/$evalglobals`를 relation/rule 기반으로 재구성
      3. `Steps`/`Eval-expr` 계열에 대해 equational context에서 쓸 다른 witness 표현 설계
  - 현재까지 확인된 의존성 체인:
    - `Steps/trans`
      → `Eval-expr`
      → `$evalexprs`, `$evalglobals`
      → `$evalexprss`, `$instantiate`
    - 즉 `prove`를 없애려면 `Steps`/`Eval-expr`만 바꾸는 것으로 끝나지 않고,
      이를 `ceq` 조건에서 참조하는 DecD/DefD들도 같이 rewrite-aware lowering으로 옮겨야 한다.
  - 참고:
    - parse warning이 있어도 현재 fib 3개 검증은 여전히 통과했다.
    - 그러나 parse warning이 있는 상태를 성공으로 보고하면 안 된다.
- [ ] **미변환 22개 execution rule 자동 변환**
  - `instrs` context heating/cooling 복구
  - `RulePr`가 있는 non-context Step rule lowering
  - `Expand` / `Ref_ok` / `Reftype_sub` 같은 premise 결과를 RHS 조립에 연결
  - `IterE` / `IterPr` 기반 반복 시퀀스 처리
  - `call_ref-func` 같은 수동 harness rule을 translator로 흡수
- [ ] **warning/advisory 우선 정리**
  - `load output.maude` 기준 `multiple distinct parses` 37건
  - `assignment condition already bound` 8건
  - `load wasm-exec.maude` 기준 `MC-I` bind-before-use 1건
  - import advisory 정리
- [ ] **isomorphic 구조 정리**
  - rule은 필요한 곳에만 `rl/crl`
  - 일반 판정은 가능하면 `mb/cmb`
  - evaluation context는 translator 자동 생성으로 최대한 통일
  - `wasm-exec.maude` 수동 override 최소화
- [x] 선택 통합 1단계: `translate_step_reld`를 rl/crl 기반으로 전환
- [x] 선택 통합 2단계: context 규칙 자동 생성 경로(`is_ctxt_rule`, `try_decode_ctxt_conclusion`, heat/cool) 이식
- [x] 통합 제외 항목 고정: RelD Bool 반환, type-ok 체계, rollrt 특수 브리지
- [x] **P0-0 재설계**: Step/Step-pure/Step-read 번역을 `rl/crl` 로 이행
- [x] 타입 판정류 `*-ok` relation을 `mb/cmb ... : ValidJudgement`로 복귀
  - `translator.ml`의 `translate_reld`에서 `*-ok` relation만 membership judgement로 분기
  - `translate_prem`도 같이 수정해서 타입 판정류 premise는 `prove(...) : Proved` 대신 `... : ValidJudgement`를 사용
  - `output.maude` 기준 확인:
    - `Numtype-ok`, `Valtype-ok`, `Memtype-ok`, `Tabletype-ok`, `Val-ok`, `Ref-ok` 등이 `cmb ... : ValidJudgement`
    - `Steps/trans` 같은 execution/연쇄 relation은 계속 `crl`
  - 재검증:
    - `rewrite [10000] in WASM-FIB : steps(fib-config(i32v(5))) .` → 최종 `i32 5`
    - `red in WASM-FIB-PROPS : modelCheck(fib-config(i32v(5)), <> result-is(5)) .` → `true`
    - `red in WASM-FIB-PROPS : modelCheck(fib-config(i32v(5)), [] ~ trap-seen) .` → `true`
- [x] fib `rewrite` / `modelCheck` 재검증
- [x] `fib(0)` ~ `fib(5)`를 각각 개별 실행해 기대 수열 확인
- [ ] `STATUS.md` 기준 warning 목록화 및 분류
- [x] `STATUS.md` 기준 warning 목록화 및 1차 분류
- [ ] **P0-B 디버그**: `wip/p0-v128-overflow` 브랜치에서
  - `output.maude:2275`의 `mb (T hasType (vN(N))) : WellTyped .` 가 왜 무조건인지 추적
  - T의 sort 확인 (아마 kind 레벨로 너무 넓음)
  - translator가 이 mb를 어느 SpecTec 규칙에서 어떻게 생성하는지 로그 추가
  - 해결책: (a) mb에 `T : SomeNarrowerSort` 조건 추가, (b) V128 cmb를 `owise`로, (c) hasType 시스템 재설계
- [ ] **커밋** (작성자 `minsung-phy`, Claude 공저자 표시 없음)
- [ ] **수동 브릿지 9종 자동화**: `wasm-exec.maude`의 `[step-*-manual]` 규칙들을 `translator.ml`에서 자동 생성하도록 이식. (Generalization 고도화)
- [ ] **IterPr / IterE 의미 보존 lowering**: 시퀀스 반복(`val*`, `val^n`) 패턴의 정석적 번역 로직 설계.

### 단기 (1-2 세션)
- [ ] P0-C 경고 체계적으로 해결 또는 suppress 근거 문서화
- [ ] **전체 변환 감사 자동화**
  - `syntax / relation / def / rule` 별로 source 개수와 생성물 대응 수를 재현 가능하게 뽑는 스크립트 작성
  - 현재 직접 확인된 미변환 22개(rule)를 기준선으로 유지
- [ ] translator 커버리지 수치: SpecTec 전체 rule 수 vs 자동 번역 성공 수
- [ ] "translator가 번역 못 하는 규칙" 목록화 및 원인 분석
- [ ] `wasm-exec.maude`에 남아 있는 수동 override와 자동 생성 경로를 다시 정리
- [ ] **fib 외 회귀 검증 확대**
  - factorial, recursive call, memory/table/GC 예제 추가
  - translator 수정이 fib harness 특화인지 여부 확인

### 중기 (1-2 주)
- [ ] P1 후속: eval-context 자동 생성 정리
  - label/frame/handler 자동 생성 경로와 `wasm-exec.maude` 수동 rule의 중복 제거
  - `instrs` context는 어떤 제약 아래서만 안전한지 재설계
- [ ] fib 외 예제 확장 (factorial, recursive call)
- [ ] memory ops, table ops 지원 범위 확인

### 장기 (논문/발표 준비)
- [ ] 벤치마크 표 (각 예제별 실행 시간, 자동 번역 비율)
- [ ] Translator 아키텍처 설명 문서 (현재는 `labmeeting.md`의 4 패턴이 전부)
- [ ] SpecTec ↔ Maude semantic preservation 논증

---

## 4. 브랜치 상태

| 브랜치 | 상태 | 비고 |
|--------|------|------|
| `main` | fib modelCheck deadlock (현재) | HEAD `59e8dc2`, 워킹트리 변경(`translator.ml`, `output.maude`) |
| `wip/p0-v128-overflow` | step() stack overflow | P0 WIP 저장, 재개 시 여기서부터 |

---

## 5. 다음 세션 진입점

1. `prove` 완전 제거 blocker를 푼다
   - `Steps` / `Eval-expr` rewrite judgement를 `DecD/DefD`에서 어떻게 참조할지 새 lowering 필요
   - 특히 `$evalexprs`, `$evalglobals`가 `Eval-expr(...) => valid`를 `ceq` 조건에서 직접 쓰지 않게 바꿔야 한다
   - 그 다음 영향 범위는 `$evalexprss`, `$instantiate`까지 재귀적으로 따라간다
2. 미변환 22개 rule을 네 부류로 나눠 translator 경로를 설계한다
   - `instrs` context
   - success-branch cast/ref/call-ref
   - struct/throw allocation-update
   - array/data/iter sequence 조립
3. warning 3대 묶음을 줄인다
   - `multiple distinct parses` 37건
   - `assignment condition already bound` 8건
   - `wasm-exec.maude`의 `MC-I` bind-before-use 1건
4. 전체 변환 감사 스크립트를 만든다
   - `syntax / relation / def / rule` 각각에 대해 source 수와 생성물 대응 수를 재현 가능하게 출력
5. fib 외 예제로 회귀 검증 범위를 넓힌다

---

## 6. 2026-04-20 업데이트

### ✅ `prove` 레이어 제거 완료
- 현재 재생성본 `output.maude` 기준:
  - `prove`: 0
  - `proved`: 0
  - `ProofState`: 0
  - `Proved`: 0
- 즉 Gemini가 넣었던 `prove(...) => proved` 중간 레이어는 생성물에서 완전히 사라졌다.

### ✅ relation 분류 최신 상태
- `*-ok`, `*-sub`, `Expand`, `Expand-use`:
  - `mb/cmb ... : ValidJudgement`
- `Steps`:
  - `crl Steps(...) => valid`
- `Eval-expr`:
  - `crl Eval-expr(...) => valid`

### ✅ `ceq` 안의 `=>` parse blocker 해결
- 원인:
  - `Eval-expr(...) => valid`가 `$evalexprs`, `$evalglobals` 같은 `DecD`의 `ceq ... if ...` 조건 안으로 들어가 parse error를 냈다.
- 해결:
  - `translator.ml`의 `translate_decd`에 rewrite-aware lowering을 추가했다.
  - rewrite judgement 또는 rewrite-dependent def call을 참조하는 clause는 `eq/ceq` 대신 `rl/crl`로 내린다.
  - 해당 조건도
    - 이전: `(... == $evalglobals(...)) = true`
    - 현재: `$evalglobals(...) => ...`
    형태로 직접 rewrite condition으로 바꾼다.
- 현재 실제 생성물:
  - `crl [eval-expr-r0] : Eval-expr(...) => valid`
  - `crl [evalexprs-r1] : $evalexprs(...) => ...`
  - `crl [evalglobals-r1] : $evalglobals(...) => ...`
- `maude -no-banner output.maude` 확인 결과, 이전의
  - `didn't expect token =>`
  - `no parse for statement`
  는 더 이상 나타나지 않는다.

### ✅ 재검증
- `rewrite [10000] in WASM-FIB : steps(fib-config(i32v(5))) .`
  - 종료
  - 최종 결과 핵심: `CTORCONSTA2(CTORI32A0, 5)`
- `red in WASM-FIB-PROPS : modelCheck(fib-config(i32v(5)), <> result-is(5)) .`
  - `result Bool: true`
- `red in WASM-FIB-PROPS : modelCheck(fib-config(i32v(5)), [] ~ trap-seen) .`
  - `result Bool: true`

### 남은 이슈
- `multiple distinct parses` 경고 다수는 여전히 남아 있다.
- `assignment condition already bound` advisory 8건도 남아 있다.
- `wasm-exec.maude`의 `MC-I` bind-before-use 1건도 남아 있다.
- `evalexprss` / `instantiate` rewrite-aware 정리도 추가 반영했다.
  - `crl [evalexprss-r1]`가 생성되고, 자기 재귀 호출도 `=>` 조건으로 내려간다.
  - `crl [instantiate-r0]` 안의 `$evalglobals`, `$evalexprs`, `$evalexprss`, `$allocmodule` 호출이 모두 rewrite condition으로 내려간다.
  - 즉 이 묶음의 혼합형 lowering은 현재 기준으로 해소됐다.

### 다음 우선순위
1. 미변환 22개 execution rule 자동변환 재개
2. warning/advisory 정리
3. fib 외 회귀 검증 확대

---

## 7. 2026-04-21 baseline translator (`translator_bs.ml`) 착수

### 목표
- `translator_bs.ml`는 `-- Step:`이 붙은 rule을 heating/cooling 없이 direct conditional `crl`로 1:1 변환하는 baseline translator다.
- 목적은 `translator.ml`의 heating/cooling 기반 번역과 결과/실행 시간을 비교하는 기준선을 만드는 것이다.
- baseline 원칙:
  - 느려도 correct
  - 일반화/최적화보다 직역 우선
  - dynamic rule이 참조하는 static judgement는 `mb/cmb`가 아니라 `eq/ceq ... = valid`

### 현재 완료
- `translator_bs.ml`, `main_bs.ml`, `dune` executable 분리 완료
- baseline 출력 생성 확인:
  - `dune exec ./main_bs.exe -- wasm-3.0/*.spectec`
- baseline 출력에는 자동 heating/cooling이 아니라 direct context rule이 생성된다:
  - `crl [step-ctxt-instrs]`
  - `crl [step-ctxt-label]`
  - `crl [step-ctxt-handler]`
  - `crl [step-ctxt-frame]`
- baseline static judgement 출력은 `eq/ceq ... = valid` 경로로 바뀌었다.

### 이번 턴 수정
- `translate_step_reld`에서 heat/cool special path를 비활성화했다.
- `translate_reld`의 non-rewrite judgement를 `mb/cmb` 대신 `eq/ceq ... = valid`로 내리게 바꿨다.
- `translate_prem`의 non-rewrite relation premise는 `... == valid`를 사용하게 바꿨다.
- baseline `Step/pure` schema rule의 `PREM-Z` placeholder parse error를 제거했다.
  - 현재 `crl [step-pure]`는
    `step(< Z | INSTR >) => < Z | INSTRQ > if step(< Z | INSTR >) => < Z | INSTRQ > ...`
    형태로 생성된다.

### 현재 상태
- `/tmp/output_bs.maude`는 현재 Maude에서 load된다.
- 이전의 `PREM-Z` / `bad token` / `no parse for statement` parse blocker는 사라졌다.
- 다만 warning/advisory는 많이 남아 있다.
- 특히 bind-before-use 경고가 남는 rule들은 현재 미변환 22개와 사실상 같은 부류다:
  - `step-read-br-on-cast-succeed`
  - `step-read-br-on-cast-fail-succeed`
  - `step-read-call-ref-func`
  - `step-read-return-call-ref-frame-addr`
  - `step-throw`
  - `step-struct-new`
  - `step-struct-set-struct`
  - `step-array-new-fixed`
  - `step-array-set-array`
  - `step-read-array-init-data-oob2`
  - `step-read-array-init-data-num`

### 다음 baseline 우선순위
1. baseline output을 실제 harness와 연결해 fib 실행 가능 여부 확인
2. `-- Step:` rule catalog를 source 기준으로 뽑아 baseline coverage를 정리
3. baseline bind-before-use rule들을 패턴별로 분류
4. 그다음에만 `translator.ml` heating/cooling 일반화와 비교 시작

### 2026-04-21 baseline harness / coverage 결과
- `wasm-exec-bs.maude` 생성 완료
  - `wasm-exec.maude`에서 fib/property harness만 남기고 baseline 전용으로 분리
  - manual `step-*` override 제거
  - `restore-*` / generated heating-cooling 의존 조각 제거
  - `load output_bs` 기준으로 동작
- baseline coverage (`-- Step:` source rule 기준):
  - source: 5개
    - `Steps/trans`
    - `Step/ctxt-instrs`
    - `Step/ctxt-label`
    - `Step/ctxt-handler`
    - `Step/ctxt-frame`
  - `output_bs.maude` generated coverage: 5/5
    - `steps-trans`
    - `step-ctxt-instrs`
    - `step-ctxt-label`
    - `step-ctxt-handler`
    - `step-ctxt-frame`
- baseline fib 검증:
  - `rewrite [10000] in WASM-FIB-BS : steps(fib-config(i32v(5))) .`
    - 실패: `Fatal error: stack overflow`
  - `red in WASM-FIB-BS-PROPS : modelCheck(fib-config(i32v(5)), <> result-is(5)) .`
    - 실패: `Fatal error: stack overflow`
  - `red in WASM-FIB-BS-PROPS : modelCheck(fib-config(i32v(5)), [] ~ trap-seen) .`
    - 실패: `Fatal error: stack overflow`
- 해석:
  - baseline translator + baseline harness만으로는 아직 fib가 종료하지 않는다.
  - 즉 current baseline은 “manual override 없이 direct conditional rule만으로는 stack overflow가 난다”는 비교 기준선 역할은 확보했다.

### baseline bind-before-use 패턴 분류
- 실행 로그(`/tmp/bs_rewrite.log`) 기준 bind-before-use rule warning: 20개
- 패턴 1. cast/ref success: 4개
  - `step-read-br-on-cast-succeed`
  - `step-read-br-on-cast-fail-succeed`
  - `step-read-ref-test-true`
  - `step-read-ref-cast-succeed`
- 패턴 2. call-ref: 1개
  - `step-read-call-ref-func`
- 패턴 3. throw: 1개
  - `step-throw`
- 패턴 4. struct: 4개
  - `step-read-struct-new-default`
  - `step-read-struct-get-struct`
  - `step-struct-new`
  - `step-struct-set-struct`
- 패턴 5. array/data: 10개
  - `step-read-array-new-default`
  - `step-read-array-new-data-oob`
  - `step-read-array-new-data-num`
  - `step-read-array-get-array`
  - `step-read-array-copy-le`
  - `step-read-array-copy-gt`
  - `step-read-array-init-data-oob2`
  - `step-read-array-init-data-num`
  - `step-array-new-fixed`
  - `step-array-set-array`
- 이 20개는 baseline에서도 여전히 “hard rule” 군으로 남아 있고, 기존 미변환 22개 execution rule과 거의 같은 구조적 원인을 공유한다.

### 2026-04-21 baseline stack overflow 원인 분해
- `NOP` 단일 step은 baseline에서도 정상 종료함
  - `rew in WASM-FIB-BS : step(< fib-state(i32v(1)) | CTORNOPA0 >) .`
  - 결과: `< fib-state(i32v(1)) | eps >`
- 반면 singleton `Step-read`는 아주 작은 예제에서도 stack overflow
  - `rew in WASM-FIB-BS : step(< fib-state(i32v(1)) | CTORLOCALGETA1(1) >) .`
  - `rew in WASM-FIB-BS : step(< fib-state(i32v(1)) | CTORGLOBALGETA1(1) >) .`
  - 둘 다 `Fatal error: stack overflow`
- helper 자체는 원인이 아님
  - `red in WASM-FIB-BS : $local(fib-state(i32v(1)), 1) .` → 정상 종료, `i32 0`
  - `red in WASM-FIB-BS : $global(fib-state(i32v(1)), 1) .` → 정상 종료
- `Step/read`, `Step/pure` schema rule 제거 후에도 overflow 지속
  - 즉 원인은 schema rule 재귀만이 아님
- `step-ctxt-instrs`의 empty-focus 과매칭도 수정했지만 overflow 지속
  - `STEP-CTXT-INSTRS2-INSTR =/= eps` guard 추가 후에도 동일
- context rule 개별/전체 비활성화로도 overflow 지속
  - `SPEC2MAUDE_BS_DISABLE_CTXT=ctxt-instrs`로 `step-ctxt-instrs`를 생성하지 않아도
    `rew in WASM-FIB-BS : step(< fib-state(i32v(1)) | CTORLOCALGETA1(1) >) .`
    는 여전히 `Fatal error: stack overflow`
  - `SPEC2MAUDE_BS_DISABLE_CTXT=ctxt-label`로 `step-ctxt-label`을 생성하지 않아도 동일
  - `SPEC2MAUDE_BS_DISABLE_CTXT=ctxt-instrs,ctxt-label,ctxt-handler,ctxt-frame`
    로 context rule 4개를 전부 꺼도 동일
- 동일한 `Idx` sort condition / `$local` assignment condition을 가진 scratch conditional rule은 즉시 성공
  - 즉 `Idx` 자체나 `$local` assignment 자체가 stack overflow 원인은 아님
- 현재까지 확실하게 말할 수 있는 결론:
  - baseline stack overflow는 helper 함수나 개별 조건식 때문이 아니라,
  - `step` 위에 direct conditional rule을 대량으로 얹었을 때 Maude가 전체 `step` rule 집합의 겹침/탐색을 폭발적으로 수행하는 데서 발생한다.
  - 특히 concrete `Step-read` singleton도 full baseline `step` relation 안에서는 재귀적 proof search에 빠진다.
  - context rule을 꺼도 overflow가 남으므로, 원인은 heating/cooling 대체용 `step-ctxt-*` rule이 아니라 baseline의 full direct-conditional `step` encoding 자체다.
  - `focused-step` 중간 relation 실험도 효과가 없었다.
    - baseline rule을 `focused-step(<...>)`로 옮기고
      `rl [step-enter] : step(EC) => focused-step(EC) .`
      만 남겨도
      `step(< fib-state(i32v(1)) | CTORLOCALGETA1(1) >)`
      와 `steps(fib-config(i32v(5)))`는 여전히 `Fatal error: stack overflow`
    - 따라서 문제는 단순히 모든 conditional rule을 `step` 이름에 직접 얹은 것만이 아니라,
      baseline direct conditional encoding 전체에서 발생하는 proof search explosion이다.

### 교수님께 보고할 현재 원인 문장
- “baseline conditional encoding은 아주 작은 `LOCAL.GET`/`GLOBAL.GET` 단일 step에서도 stack overflow가 납니다. `$local/$global` helper 자체와 `Idx` 조건은 단독으로는 정상 종료하므로 원인이 아니고, full baseline의 direct conditional `step` rule set 전체가 Maude의 proof search를 폭발시키는 것이 현재 확인된 직접 원인입니다.”
- 추가 근거:
  - `step-ctxt-instrs`, `step-ctxt-label`을 각각 꺼도 동일
  - context rule 4개를 전부 꺼도 동일
  - `focused-step` 중간 relation으로 한 번 분리해도 동일
  - 따라서 현재 overflow의 직접 원인은 context rule이 아니라 baseline direct-conditional encoding 전체

---

## 8. 2026-04-24 baseline 갱신

### 구현 상태
- `translator_bs.ml`는 현재 교수님 요구사항에 맞춰 baseline 전용 direct conditional rule 생성기로 정리됐다.
- baseline의 `Step/ctxt-*`는 heating/cooling을 쓰지 않고, SpecTec conclusion/premise shape를 직접 반영해 다음 형태로 생성한다.
  - `step(< z | instrs >) => < z' | instrs' > if step(< z_inner | instrs_inner >) => < z'_inner | instrs'_inner > /\ ...`
- `focused-step` 실험은 제거했다.
  - `op focused-step`
  - `rl [step-enter]`
  - 위 둘은 현재 `output_bs.maude`에 없다.
- `Step/ctxt-instrs`의 synthetic `VALS`/`IS` wrapper를 제거했다.
  - 현재는 SpecTec의 `val* instr* instr_1*` 구조에 맞춰 한 rule 안에서 직접 `VAL INSTR INSTR1` 형태로 생성한다.
- RHS 또는 premise 결과에만 등장하는 scalar 변수의 type guard가 누락되던 문제를 수정했다.
  - 예: `Step/ctxt-frame`에서 `SQ : Store`, `FQQ : Frame` guard가 생성된다.
  - `Step/ctxt-instrs`에서도 `ZQ : State` guard가 생성된다.
- sequence 변수의 full `hasType(list(instr))` guard는 여전히 baseline에서 생략한다.
  - 이유: Maude의 associative sequence 위에서 list membership guard를 대량으로 넣으면 탐색 비용이 커지고, 현재 baseline의 핵심 비교 대상은 scalar binder 보존 + direct `step` 조건식이다.
  - `val*` prefix는 SpecTec side condition 보존을 위해 `all-vals(VAL) = true`로 유지한다.

### 검증
- `dune build ./main_bs.exe` 성공
- `dune exec ./main_bs.exe -- wasm-3.0/* > output_bs.maude` 성공
- `maude -no-banner output_bs.maude` load 성공
- `output_bs.maude` 기준 확인:
  - `focused-step` 없음
  - `step-enter` 없음
  - `heat-step-ctxt-*` / `cool-step-ctxt-*` 없음
  - `step-ctxt-instrs`, `step-ctxt-label`, `step-ctxt-handler`, `step-ctxt-frame`는 direct conditional `crl`

### baseline stack overflow 결론
- 현재 baseline은 `output_bs.maude` 자체는 load되지만, fib 실행/model checking은 stack overflow가 난다.
- 현재까지의 원인 분해 결론:
  - `NOP` 단일 step은 종료한다.
  - `LOCAL.GET` / `GLOBAL.GET` 같은 작은 singleton `Step-read`도 full baseline rule set에서는 stack overflow가 난다.
  - `$local`, `$global`, `Idx` 조건은 단독으로는 정상 종료한다.
  - `step-ctxt-instrs`, `step-ctxt-label`, `step-ctxt-handler`, `step-ctxt-frame`을 꺼도 overflow가 남는다.
  - 따라서 overflow의 직접 원인은 context rule 자체가 아니라, direct conditional `step` rule을 대량으로 같은 relation에 얹었을 때 Maude가 겹치는 조건부 규칙들의 proof search를 폭발적으로 시도하는 구조다.

### 교수님께 보고할 표현
- 짧은 버전:
  - “교수님 말씀대로 baseline을 heating/cooling 없이 direct conditional `crl`로 만들었고, `-- Step:` context rule 5개는 SpecTec shape에 맞춰 생성됩니다. 그런데 이 baseline은 fib는 물론 `LOCAL.GET` 단일 step에서도 stack overflow가 납니다. `$local/$global` helper나 `Idx` 조건은 단독으로 정상 종료하고, context rule들을 모두 꺼도 overflow가 남기 때문에, 현재 직접 원인은 context rule이 아니라 full direct-conditional `step` rule set에서 Maude의 조건부 rewrite proof search가 폭발하는 것입니다.”
- 조금 더 정확한 버전:
  - “즉 `crl`을 쓰면 항상 안 된다는 뜻은 아니고, SpecTec의 Step relation을 거의 1:1로 하나의 executable `step` relation에 직접 올리는 baseline 방식이 Maude 실행 전략과 맞지 않습니다. 그래서 이 baseline은 correctness reference/code generation comparison 용도로는 의미가 있지만, fib model checking 실행용 semantics로는 optimized translator의 heating/cooling 또는 선배 코드처럼 redex를 좁혀 주는 구조가 필요해 보입니다.”

### 다음 액션
1. 이 baseline 실패를 보고서에 정리한다.
2. 교수님께 “baseline direct `crl`은 구현했지만 실행 baseline으로는 stack overflow”라고 보고한다.
3. 이후 실행 가능한 경로는 `translator.ml`의 optimized heat/cool 경로 또는 선배 코드식 redex-localized 구조와 비교하면서, 어떤 최적화가 semantic-preserving인지 논증한다.

---

## 9. 2026-04-27 baseline nil-split 수정

### 교수님 가설 확인
- 교수님이 지적한 `nil` split 문제는 baseline `Step/ctxt-instrs`에 실제로 해당했다.
- 기존 direct conditional rule은 recursive focus가 sequence 변수 하나였다.
  - 형태: `step(< Z | VAL INSTR INSTR1 >) => ... if step(< Z | INSTR >) => ...`
  - Maude의 associative sequence matching에서는 `INSTR = eps`인 경우도 좌항 후보가 될 수 있다.
  - 이 때문에 `f(nil) f(1 2 3 4)` 같은 식의 empty-focus 분해가 proof search에 들어갈 수 있었다.
- 수정 후에는 recursive focus를 구조적으로 non-empty로 만든다.
  - 생성 형태: `step(< Z | VAL INSTR-HEAD INSTR-REST INSTR1 >) => ...`
  - `INSTR-HEAD : WasmTerminal`, `INSTR-REST : WasmTerminals`
  - 따라서 recursive premise는 항상 `step(< Z | INSTR-HEAD INSTR-REST >) => ...`이고, focus 전체가 `eps`가 되는 match는 좌항에서부터 불가능하다.

### 구현 상태
- `translator_bs.ml`에서 `Step/ctxt-instrs` rule만 일반적인 token rewrite 방식으로 focus 변수를 `HEAD REST`로 분해한다.
  - rule-specific Maude 코드를 하드코딩한 것이 아니라, 생성된 Maude 변수 토큰을 구조적으로 교체한다.
- `Step/ctxt-instrs`의 condition 순서를 조정했다.
  - `all-vals(VAL) = true`
  - `(VAL =/= eps or INSTR1 =/= eps) = true`
  - recursive `step(< Z | INSTR-HEAD INSTR-REST >) => ...`
- baseline 실행 중 `Z : State` membership guard가 record-normalized concrete state에 대해 실패해 `LOCAL.GET` 같은 실제 step 적용을 막는 문제가 별도로 확인됐다.
  - 현재 baseline에서는 `Step*` relation의 `: State` guard를 executable condition에서 제외한다.
  - 해석: SpecTec metavariable sort annotation을 Maude proof obligation으로 매번 실행하지 않고, `< Z | ... >` configuration shape와 harness typing에 맡기는 방식이다.
  - 더 엄격한 장기 해법은 `State` membership을 record representation에 대해 정확히 생성하는 것이다.
- `wasm-exec-bs.maude`에는 fib harness용 concrete value membership을 추가했다.
  - `mb CTORCONSTA2(CTORI32A0, I:Int) : Val .`

### 검증 결과
- build/regenerate:
  - `dune build` 성공
  - `dune exec ./main_bs.exe -- wasm-3.0/* > output_bs.maude` 성공
- singleton step:
  - `rew [1] in WASM-FIB-BS : step(< fib-state(i32v(1)) | CTORLOCALGETA1(1) >) .`
  - 결과: `CTORCONSTA2(CTORI32A0, 0)`로 정상 step
- fib rewrite:
  - `rew [10000] in WASM-FIB-BS : steps(fib-config(i32v(5))) .`
  - 결과: 24,902 rewrites, 최종 instruction `CTORCONSTA2(CTORI32A0, 5)`
- baseline modelCheck:
  - `modelCheck(fib-config(i32v(2)), <> result-is(1))`도 60초 제한에서 종료하지 못했다.
  - 따라서 현재 baseline은 “stack overflow 없이 fib rewrite는 가능한 direct-crl artifact”까지 개선됐지만, “model checking 가능한 baseline”은 아직 아니다.

### 교수님께 보고할 현재 표현
- “교수님 말씀대로 nil-split 문제가 맞았습니다. `Step/ctxt-instrs`에서 recursive focus가 sequence 변수 하나라서 `eps`로도 match될 수 있었고, 이것이 empty-focus proof search를 만들었습니다. 그래서 focus를 `INSTR-HEAD : WasmTerminal` + `INSTR-REST : WasmTerminals`로 나눠 recursive premise가 항상 non-empty instruction list를 받도록 바꿨습니다.”
- “그 결과 `LOCAL.GET` 단일 step과 `fib(5)` rewrite는 더 이상 stack overflow 없이 종료합니다. 다만 direct `crl` baseline의 modelCheck는 `fib(2)`에서도 60초 안에 끝나지 않아, 다음 병목은 stack overflow가 아니라 상태공간/proof-search 비용입니다.”
- “추가로 `Z : State` guard를 executable condition으로 두면 concrete state membership이 실패해서 rule이 적용되지 않았습니다. 현재는 Step 계열의 `State` sort annotation을 실행 조건에서 빼서 baseline을 돌렸고, 장기적으로는 State membership 생성 쪽을 정확히 고치는 것이 더 strict한 해법입니다.”
