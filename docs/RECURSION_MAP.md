# IL 구성요소 → 번역 코드 대응표

목적: 논문의 번역 규칙 하나를 보고 코드에서 그 규칙을 바로 찾을 수 있는지 확인한다.
좋은 상태는 **"IL constructor 하나 = match case 하나"** 이고, 그 case 주변에
번역이 아닌 일(순서 조정, 이름 정리, 최적화)이 섞여 있지 않은 것이다.

- 기준: HEAD `2f03724` (clean), 2026-10-03. 읽기 전용 audit이며 코드는 바꾸지 않았다.
- IL constructor 목록: [ast.ml](../spectec/lib/il/ast.ml)
- 판정: ✅ 직접 대응 / ⚠️ 대응은 있으나 다른 일이 섞임 / ⛔ 미지원(진단 메시지 있음)

## 1. 전체 흐름

```
Def.translate_script                       def.ml:564
  assume_script → specialize_script        (DefP/DefA 제거, assumed relation 처리)
  Prescan.scan                             (이름·변수·iteration·policy 사전 수집)
  Def.translate (def 하나씩 재귀)           def.ml:215
    TypD → Typd.translate
    DecD → Decd.translate
    RelD → Reld.translate
    RecD → 안쪽 def들에 재귀
    GramD, HintD → []                      (HintD는 Prescan이 이미 읽음)
  Reld.translate_contexts                  (k_heatcool, 별도)
  Iter.translate_all / translate_premise_all (반복 helper, 별도)
  normalize_module                         (뒤처리: 변수 선언·중복 정리)
```

## 2. 대응표

### def / 선언

| IL | 담당 함수 | 판정 | 메모 |
| --- | --- | --- | --- |
| `TypD` | `Typd.translate` typd.ml:264 | ✅ | `InstD`마다 `translate_inst` |
| `InstD` | `Typd.translate_inst` typd.ml:257 | ✅ | |
| `AliasT` / `StructT` / `VariantT` | `Typd.translate_deftyp` typd.ml:251 | ✅ | 3 case가 3 함수로 바로 감 |
| `DecD` | `Decd.translate` decd.ml:371 | ✅ | hint로 builtin / choice / maude_rule 분기 |
| `DefD` (보통) | `translate_equation_clause` decd.ml:210 | ⚠️ | 끝에 `schedule_conditions`(조건 순서 재배치) |
| `DefD` (membership choice) | `translate_choice_clause` decd.ml:297 | ⚠️ | 같은 재배치 |
| `RelD` | `Reld.translate` reld.ml:1008 | ✅ | policy(Execution/Compute/Check)로 분기 |
| `RuleD` (Compute/Check) | `translate_rule` → `lower_rule_body` reld.ml:170 | ⚠️ | 안에서 `normalize_conditions` 호출 |
| `RuleD` (Execution) | `lower_execution_rule` reld.ml:690 | ⚠️ | ElsePr 부정식(방법론), 재배치 |
| `RecD` | `Def.translate` def.ml:224 | ✅ | |
| `GramD`, `HintD` | `Def.translate` | ✅ | 출력 없음 |

### premise

| IL | 담당 함수 | 판정 | 메모 |
| --- | --- | --- | --- |
| premise 목록 | `Prem.translate_prems` prem.ml:871 | ⚠️ | 변수가 아직 없으면 뒤로 미루는 재배치 포함 |
| `IfPr` | `translate_ifpr` prem.ml:715 | ⚠️ | 모양별 case 9개(rewrite 호출, membership, `and`, inverse, pattern, 일반 조건) |
| `LetPr` | `translate_letpr` prem.ml:790 | ✅ | |
| `RulePr` | `translate_rulepr` prem.ml:571 | ✅ | relation policy에 따라 호출 모양 결정 |
| `ElsePr` | `translate_barrier` prem.ml:814 | ✅ | 표시만 함. 실제 부정식은 reld.ml |
| `IterPr` | `translate_barrier` prem.ml:816 | ⚠️ | 출력 요청을 `request_output` 콜백으로 밖에 알림 |
| `NegPr` | — | ⛔ | 진단 메시지 있음 |

### expression (가장 깨끗한 부분)

| IL | 담당 함수 | 판정 | 메모 |
| --- | --- | --- | --- |
| 진입점 | `Term.translate_exp` term.ml:250 | ✅ | native 값이면 `native_exp`, 아니면 `translate_value` |
| `BoolE` `NumE` `TextE` `UnE` `BinE` `CmpE` `MemE` `CvtE` | `native_exp` term.ml:256 | ✅ | case 하나 = Maude 연산 하나 |
| `VarE` `TupE` `ProjE` `CaseE` `OptE` `StrE` `DotE` `CompE` `ListE` `LiftE` `LenE` `CatE` `IdxE` `SliceE` `UpdE` `ExtE` `IfE` `CallE` `SubE` | `translate_value` term.ml:317 | ✅ | |
| `IterE` | `translate_value` → `Iter.translate_term` iter.ml:191 | ⚠️ | 호출 자리는 직접. helper 본문은 따로 생성(3절) |
| `TheE`, 이름 있는 `UncaseE`, Real `CvtE` | — | ⛔ | 진단 메시지 있음 |
| path `RootP` `IdxP` `SliceP` `DotP` | `translate_select` / `translate_update` term.ml:466, 495 | ✅ | |

### type / arg / param

| IL | 담당 함수 | 판정 | 메모 |
| --- | --- | --- | --- |
| `VarT` `BoolT` `NumT` `TextT` `IterT` | `Term.translate_typ` term.ml:197 | ✅ | `TupT`는 `translate_components`에서 처리 |
| `ExpA` `TypA` | `Term.translate_arg` term.ml:217 | ✅ | `DefA`는 사전에 제거됨 |
| `ExpP` `TypP` | param.ml | ✅ | `DefP`는 사전에 제거됨 |
| pattern 위치의 exp | `Prem.translate_pattern` prem.ml:72, `bind_pattern` prem.ml:279 | ✅ | 값 만들기와 패턴 맞추기를 따로 재귀 |

## 3. 재귀 밖에 있는 것 (정당하지만 따로 보여야 함)

이들은 IL constructor 하나에 대응하지 않는다. 고칠 대상이라기보다 논문에서
"사전 분석", "hint별 lowering", "뒤처리"로 **따로 제시**해야 하는 부분이다.

| 무엇 | 위치 | 크기 | 성격 |
| --- | --- | --- | --- |
| 사전 수집 | `Prescan.scan` prescan.ml:630 | 517줄 | 이름·변수·iteration·policy를 모음 |
| k_heatcool | `Reld.Context_rules` reld.ml:1044 | 811줄 | hint lowering |
| maude_trans | `Reld.translate_trans` reld.ml:871 | 76줄 | hint lowering |
| ElsePr 부정식 | reld.ml:275–690 | ~400줄 | **방법론 (유지)** |
| 반복 helper 생성 | `Iter.translate_all` 등 iter.ml:388–1110 | ~700줄 | IterE/IterPr용 Maude 함수 생성 |
| typed list 지원 | `Typd.Lists` typd.ml:272 | 133줄 | maude_sort hint별 list 모듈 |
| 뒤처리 | `normalize_module`, `deduplicate_conditions`, `normalize_variables` def.ml | ~200줄 | 번역 결과 정리 |

## 4. 읽기를 막는 것 (중요한 순서)

**A. 조건 순서를 정하는 곳이 세 군데다.**
같은 일("변수가 준비된 조건부터 놓기")을 세 번 따로 구현했다.

- `Prem.translate_prems` prem.ml:871: premise를 미뤘다가 다시 시도
- `Decd.schedule_conditions` decd.ml:119
- `Reld.normalize_conditions` reld.ml:117 (호출 6곳)

특히 decd와 reld 쪽은 거의 같은 코드다(`condition_ready`, `take_ready`도 두 벌).
→ 한 곳으로 모으고, "번역 후 조건 순서 정하기"라는 별도 단계로 보이게 한다.

**B. 숨은 통로가 있다.**

- `request_output` 콜백: def.ml → reld.ml(14곳) → prem.ml로 전달된다.
  IterPr가 "출력 helper가 필요하다"고 밖에 알리는 통로다.
- Prescan 레코드의 mutable 필드 `forward_requested`, `projector_requested`,
  `check_requested`를 번역 도중에 켠다.
- `Iter.translate_all`은 이 값이 바뀌면 처음부터 다시 생성한다(고정점 반복).

→ 리뷰어가 "이 helper는 왜 생겼지?"를 따라가기 어렵다. 필요한 helper를
  번역 결과의 일부로 돌려주는 방식이 더 읽기 쉽다(설계 검토 필요).

**C. optional 인자로 숨은 모드가 있다.**
`?request_output`, `?include_rule`, `?head`, `?normalize`, `?defer`.
같은 함수가 인자에 따라 다르게 동작한다. 특히 `?head`는 maude_subsume/maude_trans
처리용이고 `?normalize:false`는 translate_trans 한 곳에서만 쓴다.

**D. 중복 helper.**

- `same_term` reld.ml:449 = `Context_rules.equal_term` reld.ml:1058
- `rule_id`: hintd.ml:603, reld.ml:257, reld.ml:1054
- `remove_at`: prescan.ml:528, iter.ml:858
- `components`: prem.ml:489 = hintd.ml:607 (에러 메시지만 다름)
- `split` prem.ml:496 ≈ `take` hintd.ml:614 ≈ `split_at` reld.ml:1492
- `condition_ready`/`take_ready`: decd.ml, reld.ml (A와 같은 문제)
- `RecD` 펼치기 재귀가 prescan.ml 안에 5번 (def.ml:257 `flatten`이 이미 있음)

**E. 큰 덩어리.**
`Prescan.scan` 517줄 한 함수, `Context_rules` 811줄. 단계별 함수로 나누거나
(`scan`), 별도 파일로 뺀다(`Context_rules` → `heatcool.ml`이면 reld.ml은
RelD 번역만 남음).

**F. ElsePr 부정식은 방법론이므로 유지한다.**
코드는 그대로 두고, 섹션 맨 앞에 "겹침 필터 → 부정식 직접 생성 → 안 되면
`enabled-k` helper" 순서를 주석으로 적는 것만 한다.

## 5. 할 일 순서

| 순서 | 할 일 | 출력 변화 |
| --- | --- | --- |
| 1 | D. 중복 helper 정리 | 없어야 함 |
| 2 | A. 조건 순서 정하기를 한 곳으로 | 없어야 함 (다르면 차이 조사) |
| 3 | E. `scan` 단계 분리, `Context_rules` 파일 분리 | 없어야 함 |
| 4 | C. optional 인자 정리 | 없어야 함 |
| 5 | B. helper 요청 통로 재설계 | 없어야 함, 설계 검토 먼저 |
| 6 | F. ElsePr 주석 | 없음 |

확인 방법: 시작 전에 생성 결과(`translator/generated/*.maude`)를 저장해 두고,
각 단계 뒤 같은 명령으로 다시 생성해 diff 0 + Maude load를 확인한다.

## 6. 이번 audit의 범위

- 자세히 읽음: reld.ml, prescan.ml, term.ml(번역 핵심), prem.ml(premise 처리),
  def.ml(흐름·뒤처리), typd.ml/decd.ml(분기부).
- 개요만 봄: iter.ml의 100줄 넘는 함수 3개(`translate_projector_statements`,
  `translate_statements`, `translate_premise_statements`), hintd.ml.
  이 둘은 따로 확인이 필요하다.
- 빌드·생성·Maude 실행은 하지 않았다. 4절의 "거의 같은 코드"는 읽어서
  비교한 것이며 합친 뒤 출력이 같은지는 확인하지 않았다.
