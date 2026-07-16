type complete =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

type blocked =
  { diagnostics : Diagnostics.t list
  ; blocked_declarations : Maude_ir.generated list
  }

type materialization =
  | Complete of complete
  | Blocked of blocked

type result =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  ; blocked_declarations : Maude_ir.generated list
  }

type item =
  | Runtime_search of Runtime_search_materializer.item
  | Runtime_truth_search of Runtime_truth_search_materializer.item
  | Runtime_truth_decision of Runtime_truth_decision_materializer.item
  | Runtime_truth_worklist of Runtime_truth_worklist_materializer.item
  | Runtime_enabledness of Runtime_enabledness_materializer.item

let pending key value = { Helper_closure.key; value }

let helper_key origin reason kind =
  Helper_key.key { Helper_request.kind; reason; origin }

let pending_runtime_search_items ctx =
  Context.helpers ctx
  |> Helper.runtime_predicate_search_requests
  |> List.map (fun (name, origin, request) ->
    let reason = Runtime_search_helper.reason request in
    pending
      (helper_key origin reason (Helper_request.Runtime_predicate_search request))
      (Runtime_search { Runtime_search_materializer.name; origin; request }))

let pending_runtime_truth_search_items ctx =
  Context.helpers ctx
  |> Helper.runtime_predicate_truth_search_requests
  |> List.map (fun (name, origin, request) ->
    let reason = Runtime_truth_search_helper.reason request in
    pending
      (helper_key origin reason (Helper_request.Runtime_predicate_truth_search request))
      (Runtime_truth_search
         { Runtime_truth_search_materializer.name; origin; request }))

let pending_runtime_truth_decision_items ctx =
  Context.helpers ctx
  |> Helper.runtime_predicate_truth_decision_requests
  |> List.map (fun (name, origin, request) ->
    let reason = Runtime_truth_decision_helper.reason request in
    pending
      (helper_key origin reason (Helper_request.Runtime_predicate_truth_decision request))
      (Runtime_truth_decision
         { Runtime_truth_decision_materializer.name; origin; request }))

let pending_runtime_truth_worklist_items ctx =
  Context.helpers ctx
  |> Helper.runtime_predicate_truth_worklist_requests
  |> List.map (fun (name, origin, request) ->
    let reason = Runtime_truth_worklist_helper.reason request in
    pending
      (helper_key origin reason (Helper_request.Runtime_predicate_truth_worklist request))
      (Runtime_truth_worklist
         { Runtime_truth_worklist_materializer.name; origin; request }))

let pending_runtime_enabledness_items ctx =
  Context.helpers ctx
  |> Helper.runtime_enabledness_requests
  |> List.map (fun (name, origin, request) ->
    let reason = Runtime_enabledness_helper.reason request in
    pending
      (helper_key origin reason (Helper_request.Runtime_enabledness request))
      (Runtime_enabledness
         { Runtime_enabledness_materializer.name; origin; request }))

let pending_runtime_items ctx () =
  pending_runtime_search_items ctx
  @ pending_runtime_truth_search_items ctx
  @ pending_runtime_truth_decision_items ctx
  @ pending_runtime_truth_worklist_items ctx
  @ pending_runtime_enabledness_items ctx

let blocked_declarations = function
  | Runtime_search item ->
    Runtime_search_helper.surface
      ~helper_name:item.name ~origin:item.origin item.request
  | Runtime_truth_search item ->
    Runtime_truth_search_helper.surface
      ~helper_name:item.name ~origin:item.origin item.request
  | Runtime_truth_decision item ->
    Runtime_truth_decision_helper.surface
      ~helper_name:item.name ~origin:item.origin item.request
  | Runtime_truth_worklist item ->
    Runtime_truth_worklist_helper.surface
      ~helper_name:item.name ~origin:item.origin item.request
  | Runtime_enabledness item ->
    Runtime_enabledness_helper.surface
      ~helper_name:item.name ~origin:item.origin item.request

let materialize ctx item =
  let stage = Context.begin_stage ctx in
  let staged = Context.staged stage in
  let statements, diagnostics = match item with
  | Runtime_search item ->
    let result = Runtime_search_materializer.materialize staged [ item ] in
    result.statements, result.diagnostics
  | Runtime_truth_search item ->
    let result = Runtime_truth_search_materializer.materialize staged [ item ] in
    result.statements, result.diagnostics
  | Runtime_truth_decision item ->
    (match Runtime_truth_decision_materializer.materialize staged [ item ] with
    | Complete complete ->
      ( Runtime_truth_decision_materializer.complete_statements complete
      , Runtime_truth_decision_materializer.complete_diagnostics complete )
    | Blocked diagnostics -> [], diagnostics)
  | Runtime_truth_worklist item ->
    (match Runtime_truth_worklist_materializer.materialize staged [ item ] with
    | Complete_result complete ->
      ( Runtime_truth_worklist_materializer.complete_statements complete
      , Runtime_truth_worklist_materializer.complete_diagnostics complete )
    | Blocked_result diagnostics -> [], diagnostics)
  | Runtime_enabledness item ->
    let result = Runtime_enabledness_materializer.materialize staged [ item ] in
    result.statements, result.diagnostics
  in
  if List.exists Diagnostics.is_fatal diagnostics then
    Some
      (Blocked
         { diagnostics
         ; blocked_declarations = blocked_declarations item
         })
  else if statements = [] && diagnostics = [] then
    None
  else (
    Context.commit_stage stage;
    Some (Complete { statements; diagnostics }))

let item_origin = function
  | Runtime_search item -> item.Runtime_search_materializer.origin
  | Runtime_truth_search item -> item.Runtime_truth_search_materializer.origin
  | Runtime_truth_decision item -> item.Runtime_truth_decision_materializer.origin
  | Runtime_truth_worklist item -> item.Runtime_truth_worklist_materializer.origin
  | Runtime_enabledness item -> item.Runtime_enabledness_materializer.origin

let item_kind = function
  | Runtime_search _ -> "runtime-predicate-search"
  | Runtime_truth_search _ -> "runtime-predicate-truth-search"
  | Runtime_truth_decision _ -> "runtime-predicate-truth-decision"
  | Runtime_truth_worklist _ -> "runtime-predicate-truth-worklist"
  | Runtime_enabledness _ -> "runtime-enabledness"

let stalled_diagnostic ctx (item : item Helper_closure.pending) =
  let origin = item_origin item.value in
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin
    ~constructor:"Driver/runtime-helper-closure/non-progress"
    ~enclosing:
      (Diagnostic_provenance.enclosing
         ~context:(Context.enclosing_path ctx) origin)
    ~profile:(Context.profile_name ctx)
    ~reason:
      ("runtime helper closure made no progress for pending "
       ^ item_kind item.value ^ " request with stable key `" ^ item.key
       ^ "`; returning partial generated output would be unsound")
    ~suggestion:
      "Make the materializer emit its source-complete helper or an explicit Unsupported diagnostic, and break cyclic request registration with a stable completed dependency"
    ()

let run ctx =
  let closure =
    Helper_closure.run
      ~pending:(pending_runtime_items ctx)
      ~materialize:(materialize ctx)
  in
  let materialized : result =
    { statements =
        List.concat_map
          (function
            | Complete complete -> complete.statements
            | Blocked _ -> [])
          closure.completed
    ; diagnostics =
        List.concat_map
          (function
            | Complete complete -> complete.diagnostics
            | Blocked blocked -> blocked.diagnostics)
          closure.completed
    ; blocked_declarations =
        List.concat_map
          (function
            | Complete _ -> []
            | Blocked blocked -> blocked.blocked_declarations)
          closure.completed
    }
  in
  { materialized with
    diagnostics =
      materialized.diagnostics
      @ List.map (stalled_diagnostic ctx) closure.stalled
  }
