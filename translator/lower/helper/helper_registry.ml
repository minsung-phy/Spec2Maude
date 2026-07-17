type entry =
  { name : string
  ; request : Helper_request.request
  }

type stored_entry =
  { program_key : string
  ; entry : entry
  ; mutable uses : use list
  }

and use =
  { query_key : string
  ; mutable count : int
  }

type t = { mutable entries : stored_entry list }

type stage =
  { target : t
  ; staged : t
  }

let create () = { entries = [] }

let copy_entries entries =
  let copy_use use = { use with count = use.count } in
  List.map
    (fun stored -> { stored with uses = List.map copy_use stored.uses })
    entries

let begin_stage target =
  { target; staged = { entries = copy_entries target.entries } }

let used_name registry name =
  registry.entries
  |> List.exists (fun stored -> stored.entry.name = name)

let program_key request =
  match request.Helper_request.kind with
  | Runtime_predicate_truth_worklist request ->
    "runtime-predicate-truth-worklist:"
    ^ Digest.to_hex
        (Digest.string (Runtime_truth_worklist_helper.program_key request))
  | _ -> Helper_key.key request

let add_use query_key uses =
  match List.find_opt (fun use -> use.query_key = query_key) uses with
  | Some use ->
    use.count <- use.count + 1;
    uses
  | None -> { query_key; count = 1 } :: uses

let request registry requested =
  let query_key = Helper_key.key requested in
  let program_key = program_key requested in
  match
    List.find_opt
      (fun stored -> stored.program_key = program_key)
      registry.entries
  with
  | Some stored ->
    stored.uses <- add_use query_key stored.uses;
    stored.entry.name
  | None ->
    let name = Helper_key.name ~used:(used_name registry) requested in
    let entry = { name; request = requested } in
    let uses = [ { query_key; count = 1 } ] in
    registry.entries <- { program_key; entry; uses } :: registry.entries;
    name

let request_staged stage requested =
  request stage.staged requested

let staged stage = stage.staged

let commit_stage stage =
  stage.target.entries <- copy_entries stage.staged.entries

let find registry request =
  let query_key = Helper_key.key request in
  registry.entries
  |> List.find_opt (fun stored ->
       List.exists (fun use -> use.query_key = query_key) stored.uses)
  |> Option.map (fun stored -> stored.entry.name)

let release registry request =
  let query_key = Helper_key.key request in
  let has_query stored =
    List.exists (fun use -> use.query_key = query_key) stored.uses
  in
  match List.find_opt has_query registry.entries with
  | None -> ()
  | Some stored ->
    (match List.find_opt (fun use -> use.query_key = query_key) stored.uses with
    | Some use when use.count > 1 -> use.count <- use.count - 1
    | Some _ ->
      stored.uses <-
        List.filter (fun use -> use.query_key <> query_key) stored.uses
    | None -> ());
    if stored.uses = [] then
      registry.entries <-
        List.filter
          (fun entry -> entry.program_key <> stored.program_key)
          registry.entries

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
