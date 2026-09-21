# k_heatcool: 8개 relation rule의 source / 현재 출력 / 적용안

2026-09-21 작업 트리 기준. **적용 대상은 relation rule 8개**다. 기존 이름 `maude_context`를 `k_heatcool`로 바꾼다.

- **Source**: 실제 source 본문에 목표 `hint(k_heatcool)`을 표시했다. 실제 파일에는 현재 지원되는 `Step/ctxt-instrs`에만 hint가 있다. 나머지 7개 hint는 아래의 목표 source에만 표시했다.
- **현재 Maude**: 이름 변경 직전에 `dune exec bin/spec2maude.exe -- -o /tmp/spec2maude-k-heatcool/before.maude`로 새로 생성한 출력에서 해당 문장을 그대로 발췌했다. 보조 선언과 식별 규칙 전체는 생략했다.
- **Heat/cool 적용안**: 아직 생성되지 않는 설계용 문법이다. 변수명과 LABEL/HANDLER/FRAME 표기를 단순화했다. 선언을 포함하는 로드 가능한 완성 모듈이 아니다. ctxt-instrs는 기존 동작 구조를 표시한다.

## 적용안의 공통 계약

`요청 ~> hole`에서 요청을 실행하고, 반환된 결과로 남은 premise 또는 원래 결론을 완성한다. hole 종류는 source rule에서 생성하며 translator가 LABEL 등의 Wasm 이름을 하드코딩하지 않는다.

실행 요청과 반환 결과의 sort를 구별해야 한다. cooling은 반환 결과에만 매치하고 실행 중 요청에는 매치하면 안 된다. 저장한 hole에는 rewriting을 허용하지 않는다. 중첩 요청은 안쪽 결과부터 복원한다.

`identifyPure`와 `identifyRead`의 아래 인자·반환 형태는 **이번 비교를 위한 제안 계약**이다. 현재 구현에 있는 이름이 아니며 교수님이 지정한 정확한 signature로 확인된 것도 아니다. 입력 전체가 해당 relation의 실행 후보인지 source 패턴으로 식별하고 입력 목록을 반환한다. 실제 실행은 Step-pure/Step-read가 수행한다. 가능한 source 실행을 식별 단계에서 누락해서는 안 된다. 이 도식은 목록의 일부를 선택하지 않는다. 일부를 선택하도록 확장한다면 prefix/postfix도 반환하고 복원해야 한다.

이 도식은 완료된 실행의 연결을 설명한다. 실패한 내부 요청, Eval_expr의 비-value 중간 결과 등이 내부 정지 상태로 남을 수 있으므로, 임의의 raw Maude search/LTL이 기존 source 상태와 같다고 주장하지 않는다. 공개 상태와 한 source Step의 관찰 경계, 실패 가지 처리, 가능한 결과 보존은 구현 시 별도로 검증해야 한다.

## 1. Step/pure

### SpecTec source (목표 hint 표시)

```spectec
rule Step/pure:
  z; instr*  ~>  z; instr'*
  -- Step_pure: instr* ~> instr'*
  hint(k_heatcool)
```

### 현재 Maude (실제 생성)

```maude
crl Step(Z ; INSTR-) => Z ; INSTR--
    if Step-pure(INSTR-) => INSTR-- .
```

### Heat/cool 적용안 (설계)

```maude
crl Step(Z ; INSTRS)
  => Step-pure(INSTRS) ~> holePure(Z)
  if identifyPure(INSTRS) => INSTRS .

eq RESULT ~> holePure(Z) = Z ; RESULT .
```

`identifyPure`는 Step_pure source 패턴으로부터 생성하는 후보 식별 관계다. 여기서는 입력 전체를 후보로 돌려주는 표기를 제안한다. 실제 결과와 조건 검사는 `Step-pure`가 담당한다. `RESULT`는 InstrList 결과에 한정한다.

## 2. Step/read

### SpecTec source (목표 hint 표시)

```spectec
rule Step/read:
  z; instr*  ~>  z; instr'*
  -- Step_read: z; instr* ~> instr'*
  hint(k_heatcool)
```

### 현재 Maude (실제 생성)

```maude
crl Step(Z ; INSTR-) => Z ; INSTR--
    if Step-read(Z ; INSTR-) => INSTR-- .
```

### Heat/cool 적용안 (설계)

```maude
crl Step(Z ; INSTRS)
  => Step-read(Z ; INSTRS) ~> holeRead(Z)
  if identifyRead(Z ; INSTRS) => INSTRS .

eq RESULT ~> holeRead(Z) = Z ; RESULT .
```

`identifyRead` 역시 Step_read source 패턴에서 생성한다. `Step-read`는 instruction 목록을 반환하므로 hole에 저장한 원래 상태 Z를 다시 붙인다. `RESULT`는 InstrList 결과에 한정한다.

## 3. Step/ctxt-instrs

### SpecTec source (목표 hint 표시)

```spectec
rule Step/ctxt-instrs:
  z; val* instr* instr_1*  ~>  z'; val* instr'* instr_1*
  -- Step: z; instr* ~> z'; instr'*
  -- if val* =/= eps \/ instr_1* =/= eps
  hint(k_heatcool)
```

### 현재 Maude (실제 생성)

```maude
crl [heating-ctxt-instrs] : Step(Z ; (STACK (OP REST))) => Step(Z ; FOCUS) ~> hole(PREFIX, POSTFIX)
    if (STACK (OP REST)) =/= OP
      /\ identifyFocus(Z, STACK, OP, REST) => { PREFIX | (Z ; FOCUS) | POSTFIX }
      /\ FOCUS =/= (PREFIX (FOCUS POSTFIX)) .

eq (Z- ; INSTR--) ~> hole(PREFIX, POSTFIX) = Z- ; (PREFIX (INSTR-- POSTFIX)) .
```

### Heat/cool 적용안 (설계)

```maude
crl Step(Z ; (STACK (OP REST)))
  => Step(Z ; FOCUS) ~> holeInstrs(PREFIX, POSTFIX)
  if (STACK (OP REST)) =/= OP
    /\ identifyFocus(Z, STACK, OP, REST)
       => { PREFIX | (Z ; FOCUS) | POSTFIX }
    /\ FOCUS =/= (PREFIX (FOCUS POSTFIX)) .

eq (Z2 ; RESULT) ~> holeInstrs(PREFIX, POSTFIX)
  = Z2 ; (PREFIX (RESULT POSTFIX)) .
```

이미 heat/cool을 사용한다. 적용안은 현재 구조를 유지하고 hole 이름만 설명용으로 구별했다. 원문의 nonempty 조건에 해당하는 현재 guard도 표시했다. identifyFocus 보조 규칙 전체는 아래 현재 출력 블록에 포함하지 않았다.

## 4. Step/ctxt-label

### SpecTec source (목표 hint 표시)

```spectec
rule Step/ctxt-label:
  z; (LABEL_ n `{instr_0*} instr*)  ~>  z'; (LABEL_ n `{instr_0*} instr'*)
  -- Step: z; instr* ~> z'; instr'*
  hint(k_heatcool)
```

### 현재 Maude (실제 생성)

```maude
crl Step(Z ; (LABEL- N3 { INSTR-0- } INSTR-)) => Z- ; (LABEL- N3 { INSTR-0- } INSTR--)
    if Step(Z ; INSTR-) => Z- ; INSTR-- .
```

### Heat/cool 적용안 (설계)

```maude
rl Step(Z ; LABEL(N, INSTR0, INSTRS))
  => Step(Z ; INSTRS) ~> holeLabel(N, INSTR0) .

eq (Z2 ; RESULT) ~> holeLabel(N, INSTR0)
  = Z2 ; LABEL(N, INSTR0, RESULT) .
```

N과 INSTR0를 저장한다. RESULT는 내부 한 Step의 instruction 목록이며, 최종 값 목록일 필요가 없다.

## 5. Step/ctxt-handler

### SpecTec source (목표 hint 표시)

```spectec
rule Step/ctxt-handler:
  z; (HANDLER_ n `{catch*} instr*) ~> z'; (HANDLER_ n `{catch*} instr'*)
  -- Step: z; instr* ~> z'; instr'*
  hint(k_heatcool)
```

### 현재 Maude (실제 생성)

```maude
crl Step(Z ; (HANDLER- N3 { CATCH- } INSTR-)) => Z- ; (HANDLER- N3 { CATCH- } INSTR--)
    if Step(Z ; INSTR-) => Z- ; INSTR-- .
```

### Heat/cool 적용안 (설계)

```maude
rl Step(Z ; HANDLER(N, CATCHES, INSTRS))
  => Step(Z ; INSTRS) ~> holeHandler(N, CATCHES) .

eq (Z2 ; RESULT) ~> holeHandler(N, CATCHES)
  = Z2 ; HANDLER(N, CATCHES, RESULT) .
```

N과 catch 목록을 저장하고, 내부 실행으로 바뀐 상태 Z2와 instruction 목록을 결합한다.

## 6. Step/ctxt-frame

### SpecTec source (목표 hint 표시)

```spectec
rule Step/ctxt-frame:
  s; f; (FRAME_ n `{f'} instr*)  ~>  s'; f; (FRAME_ n `{f''} instr'*)
  -- Step: s; f'; instr* ~> s'; f''; instr'*
  hint(k_heatcool)
```

### 현재 Maude (실제 생성)

```maude
crl Step((S2 ; F) ; (FRAME- N3 { F-14 } INSTR-)) => (S- ; F) ; (FRAME- N3 { F-- } INSTR--)
    if Step((S2 ; F-14) ; INSTR-) => (S- ; F--) ; INSTR-- .
```

### Heat/cool 적용안 (설계)

```maude
rl Step((S ; Fouter) ; FRAME(N, Finner, INSTRS))
  => Step((S ; Finner) ; INSTRS) ~> holeFrame(N, Fouter) .

eq ((S2 ; Finner2) ; RESULT) ~> holeFrame(N, Fouter)
  = (S2 ; Fouter) ; FRAME(N, Finner2, RESULT) .
```

바깥 frame은 Fouter로 복원한다. store와 내부 frame은 실행 결과 S2, Finner2를 사용한다. 원래 내부 frame으로 되돌리면 source와 달라진다.

## 7. Steps/trans

### SpecTec source (목표 hint 표시)

```spectec
rule Steps/trans:
  z; instr*  ~>*  z''; instr''*
  -- Step: z; instr*  ~>  z'; instr'*
  -- Steps: z'; instr'*  ~>*  z''; instr''*
  hint(k_heatcool)
```

### 현재 Maude (실제 생성)

```maude
crl Steps(Z ; INSTR-) => Z-- ; INSTR---
    if Step(Z ; INSTR-) => Z- ; INSTR--
      /\ Steps(Z- ; INSTR--) => Z-- ; INSTR--- .
```

### Heat/cool 적용안 (설계)

```maude
rl Steps(Z ; INSTRS)
  => Step(Z ; INSTRS) ~> holeStepsNext .

eq (Z1 ; MID) ~> holeStepsNext
  = Steps(Z1 ; MID) ~> holeStepsReturn .

eq (Z2 ; RESULT) ~> holeStepsReturn
  = Z2 ; RESULT .

--- 기존 Steps/refl도 함께 유지한다.
rl Steps(Z ; INSTRS) => Z ; INSTRS .
```

첫 premise Step의 결과로 두 번째 premise Steps를 시작한다. 첫 equation은 다음 실행을 시작하는 연결 단계이고, 마지막 equation이 최종 cooling이다. holeStepsReturn은 항등 복원이라 최종 구현에서 생략 가능하다. refl은 이 8개 대상에 포함되지 않지만 0회 실행을 보존하기 위해 반드시 남는다. refl을 무조건 equation으로 바꾸면 trans 선택을 없앨 수 있다.

## 8. Eval_expr

### SpecTec source (목표 hint 표시)

```spectec
rule Eval_expr:
  z; instr*  ~>*  z'; val*
  -- Steps: z; instr*  ~>*  z'; val*
  hint(k_heatcool)
```

### 현재 Maude (실제 생성)

```maude
crl Eval-expr(Z, INSTR-) => tuple(Z- seq(VAL-))
    if Steps(Z ; INSTR-) => Z- ; VAL- .
```

### Heat/cool 적용안 (설계)

```maude
rl Eval-expr(Z, INSTRS)
  => Steps(Z ; INSTRS) ~> holeEvalExpr .

ceq (Z2 ; RESULT) ~> holeEvalExpr
  = tuple(Z2 seq(RESULT))
  if typecheck(seq(RESULT), iterList(val)) .
```

현재 source 출력 패턴은 val*다. 따라서 임의 instruction 목록을 성공 결과로 반환하면 안 된다. 위 typecheck는 현재 backend의 val* 검사를 표현한다. 구현 시 해당 패턴의 sort/membership 검사를 검증해야 한다. tuple 반환 모양은 현재 Maude 출력에 맞췄다.

## 구현 범위와 별도 사례

현재 hint 인식은 실행 premise 하나와 prefix/hole/postfix 구조만 지원한다. 위 8개를 모두 적용하려면 생성자 context, 상태 복원, 순차 실행 premise, 출력 패턴 검증까지 구현해야 한다. 이름 변경은 이 지원 범위를 넓히지 않는다.

`4.4-execution.modules.spectec`의 `$evalexprs`, `$evalglobals`에도 Eval_expr 실행 premise가 있다. 두 사례는 함수 정의 절이므로 위 relation rule 8개에는 포함하지 않았다. 모든 실행 premise를 대상으로 하는 확장 작업에서는 별도로 다뤄야 한다.

## 이번 이름 변경의 검증

- `dune build`: 성공.
- 변경 전후 같은 21개 source로 새로 생성한 Maude: byte-identical.
- 생성 로그: 출력 파일 경로만 다르고 진단 없음.
- `test/spectec_to_maude.sh`: PASS (21 files), 현재 버전 관리 출력과 일치, Maude load 진단 없음.
- 위 검사는 hint 이름 변경에 대한 확인이다. 7개 확장안 및 identifyPure/identifyRead를 구현하거나 실행 검증한 결과가 아니다.
- 이번 작업의 baseline·로그: `/tmp/spec2maude-k-heatcool/` (임시 파일).
