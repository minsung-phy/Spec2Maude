type entry =
  { name : string
  ; request : Helper_request.request
  }

type stored_entry =
  { key : string
  ; entry : entry
  ; mutable uses : int
  }

type t = { mutable entries : stored_entry list }

type stage =
  { target : t
  ; staged : t
  }

let create () = { entries = [] }

let copy_entries entries =
  List.map (fun stored -> { stored with uses = stored.uses }) entries

let begin_stage target =
  { target; staged = { entries = copy_entries target.entries } }

let used_name registry name =
  registry.entries
  |> List.exists (fun stored -> stored.entry.name = name)

let request registry request =
  let key = Helper_key.key request in
  match List.find_opt (fun stored -> stored.key = key) registry.entries with
  | Some stored ->
    stored.uses <- stored.uses + 1;
    stored.entry.name
  | None ->
    let name = Helper_key.name ~used:(used_name registry) request in
    let entry = { name; request } in
    registry.entries <- { key; entry; uses = 1 } :: registry.entries;
    name

let request_staged stage requested =
  request stage.staged requested

let staged stage = stage.staged

let commit_stage stage =
  stage.target.entries <- copy_entries stage.staged.entries

let find registry request =
  let key = Helper_key.key request in
  registry.entries
  |> List.find_opt (fun stored -> stored.key = key)
  |> Option.map (fun stored -> stored.entry.name)

let release registry request =
  let key = Helper_key.key request in
  match List.find_opt (fun stored -> stored.key = key) registry.entries with
  | None -> ()
  | Some stored when stored.uses > 1 -> stored.uses <- stored.uses - 1
  | Some _ ->
    registry.entries <- List.filter (fun stored -> stored.key <> key) registry.entries

let entries registry =
  registry.entries |> List.rev |> List.map (fun stored -> stored.entry)

let runtime_predicate_search_requests registry =
  entries registry
  |> List.filter_map (fun entry ->
    match entry.request.kind with
    | Runtime_predicate_search request ->
      Some (entry.name, entry.request.origin, request)
    | _ -> None)

let runtime_predicate_truth_search_requests registry =
  entries registry
  |> List.filter_map (fun entry ->
    match entry.request.kind with
    | Runtime_predicate_truth_search request ->
      Some (entry.name, entry.request.origin, request)
    | _ -> None)

let runtime_predicate_truth_decision_requests registry =
  entries registry
  |> List.filter_map (fun entry ->
    match entry.request.kind with
    | Runtime_predicate_truth_decision request ->
      Some (entry.name, entry.request.origin, request)
    | _ -> None)

let runtime_predicate_truth_worklist_requests registry =
  entries registry
  |> List.filter_map (fun entry ->
    match entry.request.kind with
    | Runtime_predicate_truth_worklist request ->
      Some (entry.name, entry.request.origin, request)
    | _ -> None)

let runtime_enabledness_requests registry =
  entries registry
  |> List.filter_map (fun entry ->
    match entry.request.kind with
    | Runtime_enabledness request ->
      Some (entry.name, entry.request.origin, request)
    | _ -> None)

let unmaterialized_diagnostics ~profile registry =
  entries registry
  |> List.filter_map (fun entry ->
    if Helper_key.has_materializer entry.request.kind then
      None
    else
      Some
        (Diagnostics.make
           ~category:Diagnostics.Unsupported
           ~origin:entry.request.origin
           ~constructor:"Helper/unmaterialized-request"
           ~enclosing:
             (Diagnostic_provenance.enclosing_with
                ~context:[] entry.request.origin entry.name)
           ~profile
           ~reason:
             (Printf.sprintf
                "helper request `%s` was registered, but this helper kind has no Maude materializer"
                (Helper_key.kind_name entry.request.kind))
           ~suggestion:
             "Do not register this helper until its source-preserving Maude equations/rules are implemented"
           ~source_echo:entry.request.reason
           ()))
