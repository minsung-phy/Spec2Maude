;; Property-directed executable state projection of the SpaceWasm operations
;; relevant to rejected-module table mutation.  The correspondence to the
;; pinned production source is documented in SLICE_MAPPING.md.
;;
;; Event 0: a malformed module reaches its active element segment and attempts
;;          to write its candidate module index into an imported table, before
;;          later validation rejects it.
;; Event 1: a later valid module is appended at the next module index.
;; Event 2: the already-accepted provider performs call_indirect through slot 0.
;;
;; Result classification (matching exact production replays):
;;   0 = no bad call observed in this three-event trace
;;   1 = stale reference resurrected; future private function executed
;;   2 = dangling module reference followed; interpreter index panic
;;   3 = loader mutates a shared Rc table after an invocation; unwrap panic
(module
  (global $module-count (mut i32) (i32.const 1))
  (global $table-module (mut i32) (i32.const 0))
  (global $future-module (mut i32) (i32.const -1))
  (global $table-shared (mut i32) (i32.const 0))
  (global $outcome (mut i32) (i32.const 0))

  (func $apply (param $event i32)
    ;; A panic terminates the concrete process.  Once an unsafe terminal
    ;; outcome has been recorded, later abstract events are therefore ignored.
    global.get $outcome
    i32.eqz
    if
      local.get $event
      i32.eqz
      if
        ;; Element::read eventually calls Rc::get_mut(...).unwrap().  After a
        ;; provider invocation the engine retains another table reference, so
        ;; a later imported-table initialization aborts before it can commit.
        global.get $table-shared
        if
          i32.const 3
          global.set $outcome
        else
          ;; Before any invocation, Element::read writes
          ;; ModuleRef(store.modules().len()) directly into the imported table.
          ;; Rejection leaves module-count unchanged.
          global.get $module-count
          global.set $table-module
        end
      else
        local.get $event
        i32.const 1
        i32.eq
        if
          ;; Engine::push_module assigns the current module-count and then
          ;; increments the number of accepted modules.
          global.get $module-count
          global.set $future-module
          global.get $module-count
          i32.const 1
          i32.add
          global.set $module-count
        else
          ;; call_indirect first follows the table's module index.  An index at
          ;; or beyond module-count is the observed production bounds panic.
          global.get $table-module
          global.get $module-count
          i32.ge_u
          if
            i32.const 2
            global.set $outcome
          else
            ;; If a later module reused the rejected candidate's index, the
            ;; stale reference now calls that module's private function.
            global.get $future-module
            i32.const 0
            i32.ge_s
            global.get $table-module
            global.get $future-module
            i32.eq
            i32.and
            if
              i32.const 1
              global.set $outcome
            else
              ;; A completed provider invocation leaves the table shared by
              ;; the engine state, which is relevant to a later loader event.
              i32.const 1
              global.set $table-shared
            end
          end
        end
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
    global.set $table-shared
    i32.const 0
    global.set $outcome

    local.get $event0
    call $apply
    local.get $event1
    call $apply
    local.get $event2
    call $apply

    global.get $outcome)
)
