type entry =
  { name : string
  ; request : Helper_request.request
  }

type stored_entry =
  { key : string
  ; entry : entry
  }

type t = { mutable entries : stored_entry list }

let create () = { entries = [] }

let used_name registry name =
  registry.entries
  |> List.exists (fun stored -> stored.entry.name = name)

let request registry request =
  let key = Helper_key.key request in
  match List.find_opt (fun stored -> stored.key = key) registry.entries with
  | Some stored -> stored.entry.name
  | None ->
    let name = Helper_key.name ~used:(used_name registry) request in
    let entry = { name; request } in
    registry.entries <- registry.entries @ [ { key; entry } ];
    name

let entries registry =
  registry.entries |> List.map (fun stored -> stored.entry)

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
           ~enclosing:[ entry.name ]
           ~profile
           ~reason:
             (Printf.sprintf
                "helper request `%s` was registered, but this helper kind has no Maude materializer"
                (Helper_key.kind_name entry.request.kind))
           ~suggestion:
             "Do not register this helper until its source-preserving Maude equations/rules are implemented"
           ~source_echo:entry.request.reason
           ()))
