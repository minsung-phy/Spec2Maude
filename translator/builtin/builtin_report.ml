open Builtin_registry

let escape_markdown_cell text =
  text |> String.split_on_char '\n' |> String.concat "<br>"
  |> String.map (function '|' -> '/' | ch -> ch)

let code text = Printf.sprintf "%c%s%c" '\x60' text '\x60'

let signature_to_string = function
  | None -> "DecD signature not found"
  | Some signature ->
    let params =
      match signature.params with
      | [] -> "()"
      | params -> "(" ^ String.concat ", " params ^ ")"
    in
    let static =
      if signature.has_static_params then "; static params" else ""
    in
    Printf.sprintf "%s : %s; clauses=%d%s"
      params signature.result signature.source_clauses static

let status_to_string = function
  | Implemented -> "IMPLEMENTED"
  | Obligation -> "OBLIGATION"

let activity_to_string = function
  | Active -> "ACTIVE"
  | Dormant -> "DORMANT"

let requirement_source_to_string = function
  | Hint_builtin -> "hint(builtin)"
  | Declaration_only -> "declaration-only DecD"
  | Equational_view -> "relation equational view"
  | Relation_surface -> "declaration-only RelD"

let count predicate entries =
  entries |> List.filter predicate |> List.length

let provenance backend entry =
  match entry.backend_requirement, entry.backend_issue with
  | Some _, None ->
    Builtin_backend.contract_path backend ^ " / "
    ^ Builtin_backend.source backend ^ " at revision "
    ^ Builtin_backend.revision backend
  | Some _, Some issue ->
    Builtin_backend.contract_path backend ^ ": " ^ issue
  | None, Some issue -> issue
  | None, None -> "no backend ABI requirement"

let render_markdown backend registry =
  let entries = Builtin_registry.entries registry in
  let implemented = count (fun entry -> entry.status = Implemented) entries in
  let obligations = count (fun entry -> entry.status = Obligation) entries in
  let active_obligations =
    count (fun entry ->
      entry.status = Obligation && entry.activity = Active) entries
  in
  let dormant = count (fun entry -> entry.activity = Dormant) entries in
  let header =
    [ "# Builtin Obligations"
    ; ""
    ; "This file compares source-derived backend requirements with the declarative builtin ABI contract and activity in emitted Maude."
    ; "An " ^ code "OBLIGATION"
      ^ " entry has no backend equation supplied by the translator."
    ; ""
    ; "- backend semantics: " ^ code (Builtin_backend.name backend)
    ; "- backend contract: " ^ Builtin_backend.description backend
    ; Printf.sprintf "- backend ABI: %s version %d"
        (code (Builtin_backend.module_name backend)) (Builtin_backend.abi backend)
    ; "- smoke fixture: " ^ code (Builtin_backend.smoke_fixture backend)
    ; Printf.sprintf "- total: %d" (List.length entries)
    ; Printf.sprintf "- implemented: %d" implemented
    ; Printf.sprintf "- semantic obligations: %d" obligations
    ; Printf.sprintf "- active obligations: %d" active_obligations
    ; Printf.sprintf "- dormant: %d" dormant
    ; ""
    ; "| Source def | Requirement source | Activity | Location | Maude op stem | Signature | Status | Backend contract/source |"
    ; "|---|---|---|---:|---|---|---|---|"
    ]
  in
  let rows =
    entries
    |> List.map (fun entry ->
      Printf.sprintf "| %s | %s | %s | %s | %s | %s | %s | %s |"
        (code (escape_markdown_cell entry.source_id))
        (requirement_source_to_string entry.requirement_source)
        (code (activity_to_string entry.activity))
        (code (escape_markdown_cell entry.hint_location))
        (code (escape_markdown_cell entry.generated_op_stem))
        (escape_markdown_cell (signature_to_string entry.signature))
        (code (status_to_string entry.status))
        (escape_markdown_cell (provenance backend entry)))
  in
  String.concat "\n" (header @ rows) ^ "\n"
