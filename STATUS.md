# Spec2Maude — 현재 상태 / 문제점 / 할일

작성일: 2026-04-19

---

## 1. 잘한 점 (이미 된 것)

### 번역기 (translator.ml)
- SpecTec IL AST → Maude 변환 파이프라인 동작
- TypD 처리 (AliasT/StructT/VariantT) → sort membership / hasType 기반 WellTyped
- DecD/DefD → Maude eq/ceq 함수식
- RelD 4 패턴 확립 (`labmeeting.md` 참조)
  1. 일반 판정 RelD → `cmb ... : ValidJudgement`
  2. Step-pure → `ceq step(< Z | VALS instr IS >) = ...`
  3. Step-read → 상태 z 유지하며 읽기
  4. Step → z → z' 상태 변화
- `$rollrt` 하드코딩 브릿지 제거 (commit `11c341b`)

### 실행 인프라 (wasm-exec.maude)
- 손수 작성한 eval-context 규칙 (label/frame/handler/loop)
- WASM-FIB 모듈 (fib-config, fib-body, fib-loop-body)
- 모델체킹 설정 (`result-is`, `trap-seen` atomic props)
- `modelCheck(fib-config(i32v(5)), <> result-is(5))` 실행 자체는 가능 (결과는 아래 문제점 참조)

### 산출물
- `output.maude` 7,200여 줄 자동 생성
- 랩미팅용 패턴 설명 문서 `labmeeting.md` 작성

---

## 2. 현재 문제점

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
