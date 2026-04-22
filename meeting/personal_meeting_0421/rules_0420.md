# Full Rule Pattern Inventory on 2026-04-20

이 문서는 현재 `wasm-3.0/*.spectec`와 `output.maude`를 기준으로, rule 패턴별 source inventory와 generated Maude inventory를 정리한 문서다.

핵심 수치:

- Spectec 전체 `rule`: 501개
- source 기준 주요 execution 분류:
  - `Steps/*`: 2개
  - `Step_pure/*`: 79개
  - `Step_read/*`: 105개
  - `Step/*`: 32개
- 현재 `output.maude` 기준 주요 generated execution 라벨:
  - `step-pure-*`: 79개
  - `step-read-*`: 89개
  - `step-*`: 189개
  - `heat-step-ctxt-*`: 3개
  - `cool-step-ctxt-*`: 6개

주의:

- source `Step/*` 안에는 schema rule인 `Step/pure`, `Step/read`, context rule, 일반 state-changing rule이 같이 섞여 있다.
- output `step-*` 개수는 `step-pure-*`, `step-read-*`를 포함해서 집계된 값이다.
- 현재 auto-generated evaluation context는 `label/handler/frame`만 있다.
- `instrs` context는 아직 auto-generated되지 않는다.
- `wasm-exec.maude`에는 일부 manual execution rule이 남아 있다.

## 1. Source Pattern Inventory

### 1.1 `Steps/*`

```text
wasm-3.0/4.3-execution.instructions.spectec:21:Steps/refl
wasm-3.0/4.3-execution.instructions.spectec:24:Steps/trans
```

### 1.2 `Step_pure/*` (79)

```text
wasm-3.0/4.3-execution.instructions.spectec:52:Step_pure/unreachable
wasm-3.0/4.3-execution.instructions.spectec:55:Step_pure/nop
wasm-3.0/4.3-execution.instructions.spectec:58:Step_pure/drop
wasm-3.0/4.3-execution.instructions.spectec:62:Step_pure/select-true
wasm-3.0/4.3-execution.instructions.spectec:66:Step_pure/select-false
wasm-3.0/4.3-execution.instructions.spectec:85:Step_pure/if-true
wasm-3.0/4.3-execution.instructions.spectec:89:Step_pure/if-false
wasm-3.0/4.3-execution.instructions.spectec:94:Step_pure/label-vals
wasm-3.0/4.3-execution.instructions.spectec:101:Step_pure/br-label-zero
wasm-3.0/4.3-execution.instructions.spectec:105:Step_pure/br-label-succ
wasm-3.0/4.3-execution.instructions.spectec:109:Step_pure/br-handler
wasm-3.0/4.3-execution.instructions.spectec:113:Step_pure/br_if-true
wasm-3.0/4.3-execution.instructions.spectec:117:Step_pure/br_if-false
wasm-3.0/4.3-execution.instructions.spectec:122:Step_pure/br_table-lt
wasm-3.0/4.3-execution.instructions.spectec:126:Step_pure/br_table-ge
wasm-3.0/4.3-execution.instructions.spectec:131:Step_pure/br_on_null-null
wasm-3.0/4.3-execution.instructions.spectec:135:Step_pure/br_on_null-addr
wasm-3.0/4.3-execution.instructions.spectec:140:Step_pure/br_on_non_null-null
wasm-3.0/4.3-execution.instructions.spectec:144:Step_pure/br_on_non_null-addr
wasm-3.0/4.3-execution.instructions.spectec:209:Step_pure/call_indirect
wasm-3.0/4.3-execution.instructions.spectec:212:Step_pure/return_call_indirect
wasm-3.0/4.3-execution.instructions.spectec:216:Step_pure/frame-vals
wasm-3.0/4.3-execution.instructions.spectec:219:Step_pure/return-frame
wasm-3.0/4.3-execution.instructions.spectec:222:Step_pure/return-label
wasm-3.0/4.3-execution.instructions.spectec:225:Step_pure/return-handler
wasm-3.0/4.3-execution.instructions.spectec:283:Step_pure/handler-vals
wasm-3.0/4.3-execution.instructions.spectec:289:Step_pure/trap-instrs
wasm-3.0/4.3-execution.instructions.spectec:293:Step_pure/trap-label
wasm-3.0/4.3-execution.instructions.spectec:296:Step_pure/trap-handler
wasm-3.0/4.3-execution.instructions.spectec:299:Step_pure/trap-frame
wasm-3.0/4.3-execution.instructions.spectec:312:Step_pure/local.tee
wasm-3.0/4.3-execution.instructions.spectec:631:Step_pure/ref.i31
wasm-3.0/4.3-execution.instructions.spectec:635:Step_pure/ref.is_null-true
wasm-3.0/4.3-execution.instructions.spectec:639:Step_pure/ref.is_null-false
wasm-3.0/4.3-execution.instructions.spectec:644:Step_pure/ref.as_non_null-null
wasm-3.0/4.3-execution.instructions.spectec:648:Step_pure/ref.as_non_null-addr
wasm-3.0/4.3-execution.instructions.spectec:653:Step_pure/ref.eq-null
wasm-3.0/4.3-execution.instructions.spectec:657:Step_pure/ref.eq-true
wasm-3.0/4.3-execution.instructions.spectec:662:Step_pure/ref.eq-false
wasm-3.0/4.3-execution.instructions.spectec:691:Step_pure/i31.get-null
wasm-3.0/4.3-execution.instructions.spectec:694:Step_pure/i31.get-num
wasm-3.0/4.3-execution.instructions.spectec:732:Step_pure/array.new
wasm-3.0/4.3-execution.instructions.spectec:930:Step_pure/extern.convert_any-null
wasm-3.0/4.3-execution.instructions.spectec:933:Step_pure/extern.convert_any-addr
wasm-3.0/4.3-execution.instructions.spectec:937:Step_pure/any.convert_extern-null
wasm-3.0/4.3-execution.instructions.spectec:940:Step_pure/any.convert_extern-addr
wasm-3.0/4.3-execution.instructions.spectec:946:Step_pure/unop-val
wasm-3.0/4.3-execution.instructions.spectec:950:Step_pure/unop-trap
wasm-3.0/4.3-execution.instructions.spectec:955:Step_pure/binop-val
wasm-3.0/4.3-execution.instructions.spectec:959:Step_pure/binop-trap
wasm-3.0/4.3-execution.instructions.spectec:964:Step_pure/testop
wasm-3.0/4.3-execution.instructions.spectec:968:Step_pure/relop
wasm-3.0/4.3-execution.instructions.spectec:973:Step_pure/cvtop-val
wasm-3.0/4.3-execution.instructions.spectec:977:Step_pure/cvtop-trap
wasm-3.0/4.3-execution.instructions.spectec:984:Step_pure/vvunop
wasm-3.0/4.3-execution.instructions.spectec:989:Step_pure/vvbinop
wasm-3.0/4.3-execution.instructions.spectec:994:Step_pure/vvternop
wasm-3.0/4.3-execution.instructions.spectec:1000:Step_pure/vvtestop
wasm-3.0/4.3-execution.instructions.spectec:1005:Step_pure/vunop-val
wasm-3.0/4.3-execution.instructions.spectec:1009:Step_pure/vunop-trap
wasm-3.0/4.3-execution.instructions.spectec:1014:Step_pure/vbinop-val
wasm-3.0/4.3-execution.instructions.spectec:1018:Step_pure/vbinop-trap
wasm-3.0/4.3-execution.instructions.spectec:1023:Step_pure/vternop-val
wasm-3.0/4.3-execution.instructions.spectec:1027:Step_pure/vternop-trap
wasm-3.0/4.3-execution.instructions.spectec:1032:Step_pure/vtestop
wasm-3.0/4.3-execution.instructions.spectec:1038:Step_pure/vrelop
wasm-3.0/4.3-execution.instructions.spectec:1043:Step_pure/vshiftop
wasm-3.0/4.3-execution.instructions.spectec:1048:Step_pure/vbitmask
wasm-3.0/4.3-execution.instructions.spectec:1053:Step_pure/vswizzlop
wasm-3.0/4.3-execution.instructions.spectec:1058:Step_pure/vshuffle
wasm-3.0/4.3-execution.instructions.spectec:1063:Step_pure/vsplat
wasm-3.0/4.3-execution.instructions.spectec:1068:Step_pure/vextract_lane-num
wasm-3.0/4.3-execution.instructions.spectec:1072:Step_pure/vextract_lane-pack
wasm-3.0/4.3-execution.instructions.spectec:1077:Step_pure/vreplace_lane
wasm-3.0/4.3-execution.instructions.spectec:1083:Step_pure/vextunop
wasm-3.0/4.3-execution.instructions.spectec:1088:Step_pure/vextbinop
wasm-3.0/4.3-execution.instructions.spectec:1093:Step_pure/vextternop
wasm-3.0/4.3-execution.instructions.spectec:1099:Step_pure/vnarrow
wasm-3.0/4.3-execution.instructions.spectec:1104:Step_pure/vcvtop
```

### 1.3 `Step_read/*` (105)

```text
wasm-3.0/4.3-execution.instructions.spectec:77:Step_read/block
wasm-3.0/4.3-execution.instructions.spectec:81:Step_read/loop
wasm-3.0/4.3-execution.instructions.spectec:149:Step_read/br_on_cast-succeed
wasm-3.0/4.3-execution.instructions.spectec:155:Step_read/br_on_cast-fail
wasm-3.0/4.3-execution.instructions.spectec:160:Step_read/br_on_cast_fail-succeed
wasm-3.0/4.3-execution.instructions.spectec:166:Step_read/br_on_cast_fail-fail
wasm-3.0/4.3-execution.instructions.spectec:173:Step_read/call
wasm-3.0/4.3-execution.instructions.spectec:177:Step_read/call_ref-null
wasm-3.0/4.3-execution.instructions.spectec:180:Step_read/call_ref-func
wasm-3.0/4.3-execution.instructions.spectec:189:Step_read/return_call
wasm-3.0/4.3-execution.instructions.spectec:194:Step_read/return_call_ref-label
wasm-3.0/4.3-execution.instructions.spectec:197:Step_read/return_call_ref-handler
wasm-3.0/4.3-execution.instructions.spectec:200:Step_read/return_call_ref-frame-null
wasm-3.0/4.3-execution.instructions.spectec:203:Step_read/return_call_ref-frame-addr
wasm-3.0/4.3-execution.instructions.spectec:237:Step_read/throw_ref-null
wasm-3.0/4.3-execution.instructions.spectec:240:Step_read/throw_ref-instrs
wasm-3.0/4.3-execution.instructions.spectec:245:Step_read/throw_ref-label
wasm-3.0/4.3-execution.instructions.spectec:248:Step_read/throw_ref-frame
wasm-3.0/4.3-execution.instructions.spectec:251:Step_read/throw_ref-handler-empty
wasm-3.0/4.3-execution.instructions.spectec:254:Step_read/throw_ref-handler-catch
wasm-3.0/4.3-execution.instructions.spectec:260:Step_read/throw_ref-handler-catch_ref
wasm-3.0/4.3-execution.instructions.spectec:266:Step_read/throw_ref-handler-catch_all
wasm-3.0/4.3-execution.instructions.spectec:269:Step_read/throw_ref-handler-catch_all_ref
wasm-3.0/4.3-execution.instructions.spectec:272:Step_read/throw_ref-handler-next
wasm-3.0/4.3-execution.instructions.spectec:277:Step_read/try_table
wasm-3.0/4.3-execution.instructions.spectec:305:Step_read/local.get
wasm-3.0/4.3-execution.instructions.spectec:318:Step_read/global.get
wasm-3.0/4.3-execution.instructions.spectec:328:Step_read/table.get-oob
wasm-3.0/4.3-execution.instructions.spectec:332:Step_read/table.get-val
wasm-3.0/4.3-execution.instructions.spectec:345:Step_read/table.size
wasm-3.0/4.3-execution.instructions.spectec:360:Step_read/table.fill-oob
wasm-3.0/4.3-execution.instructions.spectec:364:Step_read/table.fill-zero
wasm-3.0/4.3-execution.instructions.spectec:369:Step_read/table.fill-succ
wasm-3.0/4.3-execution.instructions.spectec:376:Step_read/table.copy-oob
wasm-3.0/4.3-execution.instructions.spectec:381:Step_read/table.copy-zero
wasm-3.0/4.3-execution.instructions.spectec:386:Step_read/table.copy-le
wasm-3.0/4.3-execution.instructions.spectec:393:Step_read/table.copy-gt
wasm-3.0/4.3-execution.instructions.spectec:400:Step_read/table.init-oob
wasm-3.0/4.3-execution.instructions.spectec:405:Step_read/table.init-zero
wasm-3.0/4.3-execution.instructions.spectec:410:Step_read/table.init-succ
wasm-3.0/4.3-execution.instructions.spectec:423:Step_read/load-num-oob
wasm-3.0/4.3-execution.instructions.spectec:428:Step_read/load-num-val
wasm-3.0/4.3-execution.instructions.spectec:433:Step_read/load-pack-oob
wasm-3.0/4.3-execution.instructions.spectec:438:Step_read/load-pack-val
wasm-3.0/4.3-execution.instructions.spectec:443:Step_read/vload-oob
wasm-3.0/4.3-execution.instructions.spectec:447:Step_read/vload-val
wasm-3.0/4.3-execution.instructions.spectec:452:Step_read/vload-pack-oob
wasm-3.0/4.3-execution.instructions.spectec:456:Step_read/vload-pack-val
wasm-3.0/4.3-execution.instructions.spectec:464:Step_read/vload-splat-oob
wasm-3.0/4.3-execution.instructions.spectec:468:Step_read/vload-splat-val
wasm-3.0/4.3-execution.instructions.spectec:477:Step_read/vload-zero-oob
wasm-3.0/4.3-execution.instructions.spectec:481:Step_read/vload-zero-val
wasm-3.0/4.3-execution.instructions.spectec:488:Step_read/vload_lane-oob
wasm-3.0/4.3-execution.instructions.spectec:492:Step_read/vload_lane-val
wasm-3.0/4.3-execution.instructions.spectec:547:Step_read/memory.size
wasm-3.0/4.3-execution.instructions.spectec:562:Step_read/memory.fill-oob
wasm-3.0/4.3-execution.instructions.spectec:566:Step_read/memory.fill-zero
wasm-3.0/4.3-execution.instructions.spectec:571:Step_read/memory.fill-succ
wasm-3.0/4.3-execution.instructions.spectec:578:Step_read/memory.copy-oob
wasm-3.0/4.3-execution.instructions.spectec:583:Step_read/memory.copy-zero
wasm-3.0/4.3-execution.instructions.spectec:588:Step_read/memory.copy-le
wasm-3.0/4.3-execution.instructions.spectec:595:Step_read/memory.copy-gt
wasm-3.0/4.3-execution.instructions.spectec:602:Step_read/memory.init-oob
wasm-3.0/4.3-execution.instructions.spectec:607:Step_read/memory.init-zero
wasm-3.0/4.3-execution.instructions.spectec:612:Step_read/memory.init-succ
wasm-3.0/4.3-execution.instructions.spectec:625:Step_read/ref.null-idx
wasm-3.0/4.3-execution.instructions.spectec:628:Step_read/ref.func
wasm-3.0/4.3-execution.instructions.spectec:667:Step_read/ref.test-true
wasm-3.0/4.3-execution.instructions.spectec:673:Step_read/ref.test-false
wasm-3.0/4.3-execution.instructions.spectec:678:Step_read/ref.cast-succeed
wasm-3.0/4.3-execution.instructions.spectec:684:Step_read/ref.cast-fail
wasm-3.0/4.3-execution.instructions.spectec:706:Step_read/struct.new_default
wasm-3.0/4.3-execution.instructions.spectec:712:Step_read/struct.get-null
wasm-3.0/4.3-execution.instructions.spectec:715:Step_read/struct.get-struct
wasm-3.0/4.3-execution.instructions.spectec:735:Step_read/array.new_default
wasm-3.0/4.3-execution.instructions.spectec:748:Step_read/array.new_elem-oob
wasm-3.0/4.3-execution.instructions.spectec:752:Step_read/array.new_elem-alloc
wasm-3.0/4.3-execution.instructions.spectec:758:Step_read/array.new_data-oob
wasm-3.0/4.3-execution.instructions.spectec:765:Step_read/array.new_data-num
wasm-3.0/4.3-execution.instructions.spectec:772:Step_read/array.get-null
wasm-3.0/4.3-execution.instructions.spectec:775:Step_read/array.get-oob
wasm-3.0/4.3-execution.instructions.spectec:779:Step_read/array.get-array
wasm-3.0/4.3-execution.instructions.spectec:798:Step_read/array.len-null
wasm-3.0/4.3-execution.instructions.spectec:801:Step_read/array.len-array
wasm-3.0/4.3-execution.instructions.spectec:805:Step_read/array.fill-null
wasm-3.0/4.3-execution.instructions.spectec:808:Step_read/array.fill-oob
wasm-3.0/4.3-execution.instructions.spectec:812:Step_read/array.fill-zero
wasm-3.0/4.3-execution.instructions.spectec:817:Step_read/array.fill-succ
wasm-3.0/4.3-execution.instructions.spectec:823:Step_read/array.copy-null1
wasm-3.0/4.3-execution.instructions.spectec:826:Step_read/array.copy-null2
wasm-3.0/4.3-execution.instructions.spectec:829:Step_read/array.copy-oob1
wasm-3.0/4.3-execution.instructions.spectec:834:Step_read/array.copy-oob2
wasm-3.0/4.3-execution.instructions.spectec:839:Step_read/array.copy-zero
wasm-3.0/4.3-execution.instructions.spectec:845:Step_read/array.copy-le
wasm-3.0/4.3-execution.instructions.spectec:857:Step_read/array.copy-gt
wasm-3.0/4.3-execution.instructions.spectec:869:Step_read/array.init_elem-null
wasm-3.0/4.3-execution.instructions.spectec:872:Step_read/array.init_elem-oob1
wasm-3.0/4.3-execution.instructions.spectec:877:Step_read/array.init_elem-oob2
wasm-3.0/4.3-execution.instructions.spectec:882:Step_read/array.init_elem-zero
wasm-3.0/4.3-execution.instructions.spectec:888:Step_read/array.init_elem-succ
wasm-3.0/4.3-execution.instructions.spectec:897:Step_read/array.init_data-null
wasm-3.0/4.3-execution.instructions.spectec:900:Step_read/array.init_data-oob1
wasm-3.0/4.3-execution.instructions.spectec:905:Step_read/array.init_data-oob2
wasm-3.0/4.3-execution.instructions.spectec:911:Step_read/array.init_data-zero
wasm-3.0/4.3-execution.instructions.spectec:918:Step_read/array.init_data-num
```

### 1.4 `Step/*` (32)

```text
wasm-3.0/4.3-execution.instructions.spectec:13:Step/pure
wasm-3.0/4.3-execution.instructions.spectec:17:Step/read
wasm-3.0/4.3-execution.instructions.spectec:32:Step/ctxt-instrs
wasm-3.0/4.3-execution.instructions.spectec:37:Step/ctxt-label
wasm-3.0/4.3-execution.instructions.spectec:41:Step/ctxt-handler
wasm-3.0/4.3-execution.instructions.spectec:45:Step/ctxt-frame
wasm-3.0/4.3-execution.instructions.spectec:231:Step/throw
wasm-3.0/4.3-execution.instructions.spectec:309:Step/local.set
wasm-3.0/4.3-execution.instructions.spectec:322:Step/global.set
wasm-3.0/4.3-execution.instructions.spectec:336:Step/table.set-oob
wasm-3.0/4.3-execution.instructions.spectec:340:Step/table.set-val
wasm-3.0/4.3-execution.instructions.spectec:351:Step/table.grow-succeed
wasm-3.0/4.3-execution.instructions.spectec:356:Step/table.grow-fail
wasm-3.0/4.3-execution.instructions.spectec:417:Step/elem.drop
wasm-3.0/4.3-execution.instructions.spectec:501:Step/store-num-oob
wasm-3.0/4.3-execution.instructions.spectec:506:Step/store-num-val
wasm-3.0/4.3-execution.instructions.spectec:512:Step/store-pack-oob
wasm-3.0/4.3-execution.instructions.spectec:517:Step/store-pack-val
wasm-3.0/4.3-execution.instructions.spectec:523:Step/vstore-oob
wasm-3.0/4.3-execution.instructions.spectec:528:Step/vstore-val
wasm-3.0/4.3-execution.instructions.spectec:534:Step/vstore_lane-oob
wasm-3.0/4.3-execution.instructions.spectec:539:Step/vstore_lane-val
wasm-3.0/4.3-execution.instructions.spectec:553:Step/memory.grow-succeed
wasm-3.0/4.3-execution.instructions.spectec:558:Step/memory.grow-fail
wasm-3.0/4.3-execution.instructions.spectec:619:Step/data.drop
wasm-3.0/4.3-execution.instructions.spectec:700:Step/struct.new
wasm-3.0/4.3-execution.instructions.spectec:721:Step/struct.set-null
wasm-3.0/4.3-execution.instructions.spectec:724:Step/struct.set-struct
wasm-3.0/4.3-execution.instructions.spectec:740:Step/array.new_fixed
wasm-3.0/4.3-execution.instructions.spectec:785:Step/array.set-null
wasm-3.0/4.3-execution.instructions.spectec:788:Step/array.set-oob
wasm-3.0/4.3-execution.instructions.spectec:792:Step/array.set-array
```

## 2. Current Generated Inventory in `output.maude`

### 2.1 `step-pure-*` labels (79)

```text
step-pure-unreachable
step-pure-nop
step-pure-drop
step-pure-select-true
step-pure-select-false
step-pure-if-true
step-pure-if-false
step-pure-label-vals
step-pure-br-label-zero
step-pure-br-label-succ
step-pure-br-handler
step-pure-br-if-true
step-pure-br-if-false
step-pure-br-table-lt
step-pure-br-table-ge
step-pure-br-on-null-null
step-pure-br-on-null-addr
step-pure-br-on-non-null-null
step-pure-br-on-non-null-addr
step-pure-call-indirect
step-pure-return-call-indirect
step-pure-frame-vals
step-pure-return-frame
step-pure-return-label
step-pure-return-handler
step-pure-handler-vals
step-pure-trap-instrs
step-pure-trap-label
step-pure-trap-handler
step-pure-trap-frame
step-pure-local-tee
step-pure-ref-i31
step-pure-ref-is-null-true
step-pure-ref-is-null-false
step-pure-ref-as-non-null-null
step-pure-ref-as-non-null-addr
step-pure-ref-eq-null
step-pure-ref-eq-true
step-pure-ref-eq-false
step-pure-i31-get-null
step-pure-i31-get-num
step-pure-array-new
step-pure-extern-convert-any-null
step-pure-extern-convert-any-addr
step-pure-any-convert-extern-null
step-pure-any-convert-extern-addr
step-pure-unop-val
step-pure-unop-trap
step-pure-binop-val
step-pure-binop-trap
step-pure-testop
step-pure-relop
step-pure-cvtop-val
step-pure-cvtop-trap
step-pure-vvunop
step-pure-vvbinop
step-pure-vvternop
step-pure-vvtestop
step-pure-vunop-val
step-pure-vunop-trap
step-pure-vbinop-val
step-pure-vbinop-trap
step-pure-vternop-val
step-pure-vternop-trap
step-pure-vtestop
step-pure-vrelop
step-pure-vshiftop
step-pure-vbitmask
step-pure-vswizzlop
step-pure-vshuffle
step-pure-vsplat
step-pure-vextract-lane-num
step-pure-vextract-lane-pack
step-pure-vreplace-lane
step-pure-vextunop
step-pure-vextbinop
step-pure-vextternop
step-pure-vnarrow
step-pure-vcvtop
```

### 2.2 `step-read-*` labels (89)

```text
step-read-block
step-read-loop
step-read-br-on-cast-fail
step-read-br-on-cast-fail-fail
step-read-call
step-read-call-ref-null
step-read-return-call
step-read-return-call-ref-label
step-read-return-call-ref-handler
step-read-return-call-ref-frame-null
step-read-throw-ref-null
step-read-throw-ref-instrs
step-read-throw-ref-label
step-read-throw-ref-frame
step-read-throw-ref-handler-empty
step-read-throw-ref-handler-catch
step-read-throw-ref-handler-catch-ref
step-read-throw-ref-handler-catch-all
step-read-throw-ref-handler-catch-all-ref
step-read-throw-ref-handler-next
step-read-try-table
step-read-local-get
step-read-global-get
step-read-table-get-oob
step-read-table-get-val
step-read-table-size
step-read-table-fill-oob
step-read-table-fill-zero
step-read-table-fill-succ
step-read-table-copy-oob
step-read-table-copy-zero
step-read-table-copy-le
step-read-table-copy-gt
step-read-table-init-oob
step-read-table-init-zero
step-read-table-init-succ
step-read-load-num-oob
step-read-load-num-val
step-read-load-pack-oob
step-read-load-pack-val
step-read-vload-oob
step-read-vload-val
step-read-vload-pack-oob
step-read-vload-pack-val
step-read-vload-splat-oob
step-read-vload-splat-val
step-read-vload-zero-oob
step-read-vload-zero-val
step-read-vload-lane-oob
step-read-vload-lane-val
step-read-memory-size
step-read-memory-fill-oob
step-read-memory-fill-zero
step-read-memory-fill-succ
step-read-memory-copy-oob
step-read-memory-copy-zero
step-read-memory-copy-le
step-read-memory-copy-gt
step-read-memory-init-oob
step-read-memory-init-zero
step-read-memory-init-succ
step-read-ref-null-idx
step-read-ref-func
step-read-ref-test-false
step-read-ref-cast-fail
step-read-struct-get-null
step-read-array-new-elem-oob
step-read-array-new-elem-alloc
step-read-array-get-null
step-read-array-get-oob
step-read-array-len-null
step-read-array-len-array
step-read-array-fill-null
step-read-array-fill-oob
step-read-array-fill-zero
step-read-array-fill-succ
step-read-array-copy-null1
step-read-array-copy-null2
step-read-array-copy-oob1
step-read-array-copy-oob2
step-read-array-copy-zero
step-read-array-init-elem-null
step-read-array-init-elem-oob1
step-read-array-init-elem-oob2
step-read-array-init-elem-zero
step-read-array-init-elem-succ
step-read-array-init-data-null
step-read-array-init-data-oob1
step-read-array-init-data-zero
```

### 2.3 current `step-*` labels

`output.maude`에서 `step-*` prefix 총수는 189개다. 이 값은 `step-pure-*`, `step-read-*`, state-changing `step-*`를 모두 포함한다.

대표적인 state-changing rule 예시:

```text
step-local-set
step-global-set
step-table-set-oob
step-table-set-val
step-table-grow-succeed
step-table-grow-fail
step-elem-drop
step-store-num-oob
step-store-num-val
step-store-pack-oob
step-store-pack-val
step-vstore-oob
step-vstore-val
step-vstore-lane-oob
step-vstore-lane-val
step-memory-grow-succeed
step-memory-grow-fail
step-data-drop
step-struct-set-null
step-array-set-null
step-array-set-oob
```

### 2.4 current auto-generated evaluation context labels

```text
heat-step-ctxt-label
cool-step-ctxt-label
cool-step-ctxt-label-control
heat-step-ctxt-handler
cool-step-ctxt-handler
cool-step-ctxt-handler-control
heat-step-ctxt-frame
cool-step-ctxt-frame
cool-step-ctxt-frame-control
```

## 3. Representative Full Code by Pattern

### 3.1 `Step_pure`

#### Spectec
출처: [wasm-3.0/4.3-execution.instructions.spectec](/Users/minsung/Dev/projects/Spec2Maude/wasm-3.0/4.3-execution.instructions.spectec:55)

```spectec
rule Step_pure/nop:
  NOP  ~>  eps
```

#### Maude
출처: [output.maude](/Users/minsung/Dev/projects/Spec2Maude/output.maude:6688)

```maude
crl [step-pure-nop] :
  step(< STEP-PURE-NOP-Z | STEP-PURE-NOP-VALS CTORNOPA0 STEP-PURE-NOP-IS >)
  =>
  < STEP-PURE-NOP-Z | STEP-PURE-NOP-VALS eps STEP-PURE-NOP-IS >
    if all-vals ( STEP-PURE-NOP-VALS ) = true .
```

### 3.2 `Step_read`

#### Spectec
출처: [wasm-3.0/4.3-execution.instructions.spectec](/Users/minsung/Dev/projects/Spec2Maude/wasm-3.0/4.3-execution.instructions.spectec:305)

```spectec
rule Step_read/local.get:
  z; (LOCAL.GET x)  ~>  val
  -- if $local(z, x) = val
```

#### Maude
출처: [output.maude](/Users/minsung/Dev/projects/Spec2Maude/output.maude:7191)

```maude
crl [step-read-local-get] :
  step(< STEP-READ-LOCAL-GET25-Z | STEP-READ-LOCAL-GET-VALS CTORLOCALGETA1 ( STEP-READ-LOCAL-GET25-X ) STEP-READ-LOCAL-GET-IS >)
  =>
  < STEP-READ-LOCAL-GET25-Z | STEP-READ-LOCAL-GET-VALS STEP-READ-LOCAL-GET25-VAL STEP-READ-LOCAL-GET-IS >
    if all-vals ( STEP-READ-LOCAL-GET-VALS ) = true /\ STEP-READ-LOCAL-GET25-VAL := $local ( STEP-READ-LOCAL-GET25-Z, STEP-READ-LOCAL-GET25-X ) /\ STEP-READ-LOCAL-GET25-Z : State /\ STEP-READ-LOCAL-GET25-X : Idx .
```

### 3.3 `Step`

#### Spectec
출처: [wasm-3.0/4.3-execution.instructions.spectec](/Users/minsung/Dev/projects/Spec2Maude/wasm-3.0/4.3-execution.instructions.spectec:309)

```spectec
rule Step/local.set:
  z; val (LOCAL.SET x)  ~>  $with_local(z, x, val); eps
```

#### Maude
출처: [output.maude](/Users/minsung/Dev/projects/Spec2Maude/output.maude:7565)

```maude
crl [step-local-set] :
  step(< STEP-LOCAL-SET7-Z | STEP-LOCAL-SET-VALS STEP-LOCAL-SET7-VAL CTORLOCALSETA1 ( STEP-LOCAL-SET7-X ) STEP-LOCAL-SET-IS >)
  =>
  < $with-local ( STEP-LOCAL-SET7-Z, STEP-LOCAL-SET7-X, STEP-LOCAL-SET7-VAL ) | STEP-LOCAL-SET-VALS eps STEP-LOCAL-SET-IS >
    if all-vals ( STEP-LOCAL-SET-VALS ) = true /\ STEP-LOCAL-SET7-Z : State /\ STEP-LOCAL-SET7-VAL : Val /\ STEP-LOCAL-SET7-X : Idx .
```

### 3.4 `Steps`

#### Spectec
출처: [wasm-3.0/4.3-execution.instructions.spectec](/Users/minsung/Dev/projects/Spec2Maude/wasm-3.0/4.3-execution.instructions.spectec:24)

```spectec
rule Steps/trans:
  z; instr*  ~>*  z''; instr''*
  -- Step: z; instr*  ~>  z'; instr'*
  -- Steps: z'; instr'*  ~>*  z''; instr''*
```

#### Maude
출처: [output.maude](/Users/minsung/Dev/projects/Spec2Maude/output.maude:7680)

```maude
crl [steps-trans] :
  Steps ( CTORSEMICOLONA2 ( STEPS-TRANS1-Z, STEPS-TRANS1-INSTR ) , CTORSEMICOLONA2 ( STEPS-TRANS1-ZQQ, STEPS-TRANS1-INSTRQQ ) )
  =>
  valid
    if step(< STEPS-TRANS1-Z | STEPS-TRANS1-INSTR >) => < STEPS-TRANS1-ZQ | STEPS-TRANS1-INSTRQ >
    /\ Steps ( ( CTORSEMICOLONA2 ( STEPS-TRANS1-ZQ, STEPS-TRANS1-INSTRQ ) ), ( CTORSEMICOLONA2 ( STEPS-TRANS1-ZQQ, STEPS-TRANS1-INSTRQQ ) ) ) => valid
    /\ STEPS-TRANS1-Z : State
    /\ ( STEPS-TRANS1-INSTR hasType ( list ( instr ) ) ) : WellTyped
    /\ STEPS-TRANS1-ZQQ : State
    /\ ( STEPS-TRANS1-INSTRQQ hasType ( list ( instr ) ) ) : WellTyped .
```

### 3.5 evaluation context

평가 문맥 전체는 [evaluation_context.md](/Users/minsung/Dev/projects/Spec2Maude/evaluation_context.md:1)에 따로 정리했다.
