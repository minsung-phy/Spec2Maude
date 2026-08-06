;; Executable reduction of the four SpaceWasm operations relevant to the
;; rejected-module table-reference bug.  The correspondence to production
;; source is documented in SLICE_MAPPING.md.
;;
;; Event 0: a malformed module executes its active element segment, writing the
;;          candidate module index into an imported table, then is rejected.
;; Event 1: a later valid module is appended at the next module index.
;; Event 2: the already-accepted provider performs call_indirect through slot 0.
;;
;; The exported function processes one occurrence of each event in the order
;; supplied by the model checker.  It returns 1 iff the rejected module's stale
;; reference is resurrected and the provider is redirected into the later
;; module's private function.
(module
  (global $module-count (mut i32) (i32.const 1))
  (global $table-module (mut i32) (i32.const 0))
  (global $future-module (mut i32) (i32.const -1))
  (global $hijacked (mut i32) (i32.const 0))

  (func $apply (param $event i32)
    ;; Rejected attacker: Element::read stores ModuleRef(store.modules().len())
    ;; into the provider's imported table.  Rejection leaves module-count
    ;; unchanged because Engine::push_module is never called.
    local.get $event
    i32.eqz
    if
      global.get $module-count
      global.set $table-module
    else
      ;; Later valid module: push_module assigns the current module-count and
      ;; then increments the number of accepted modules.
      local.get $event
      i32.const 1
      i32.eq
      if
        global.get $module-count
        global.set $future-module
        global.get $module-count
        i32.const 1
        i32.add
        global.set $module-count
      else
        ;; Provider call_indirect: a stale table ModuleRef aliases the later
        ;; module once that module has been appended at the reused index.
        global.get $future-module
        i32.const 0
        i32.ge_s
        global.get $table-module
        global.get $future-module
        i32.eq
        i32.and
        global.set $hijacked
      end
    end)

  (func (export "run3")
        (param $event0 i32) (param $event1 i32) (param $event2 i32)
        (result i32)
    i32.const 1
    global.set $module-count
    i32.const 0
    global.set $table-module
    i32.const -1
    global.set $future-module
    i32.const 0
    global.set $hijacked

    local.get $event0
    call $apply
    local.get $event1
    call $apply
    local.get $event2
    call $apply

    global.get $hijacked)
)
