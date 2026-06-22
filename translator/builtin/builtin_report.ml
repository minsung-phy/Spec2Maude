open Builtin_types

let escape_markdown_cell text =
  text
  |> String.split_on_char '\n'
  |> String.concat "<br>"
  |> String.map (function
    | '|' -> '/'
    | ch -> ch)

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

let render_markdown entries =
  let header =
    [ "# Builtin Obligations"
    ; ""
    ; "This file is derived from `hint(builtin)` declarations in the translated SpecTec source."
    ; "An `OBLIGATION` entry means the source requires a backend primitive, but this repository must not invent a default equation such as `0`, `eps`, or `false`."
    ; ""
    ; Printf.sprintf "- total: %d" (count entries)
    ; Printf.sprintf "- implemented: %d" (implemented_count entries)
    ; Printf.sprintf "- obligations: %d" (obligation_count entries)
    ; ""
    ; "| Source def | Location | Maude op stem | Signature | Status | Official semantics source | Smoke test |"
    ; "|---|---:|---|---|---|---|---|"
    ]
  in
  let rows =
    entries
    |> List.map (fun entry ->
      Printf.sprintf "| `%s` | `%s` | `%s` | %s | `%s` | %s | %s |"
        (escape_markdown_cell entry.source_id)
        (escape_markdown_cell entry.hint_location)
        (escape_markdown_cell entry.generated_op_stem)
        (escape_markdown_cell (signature_to_string entry.signature))
        (status_to_string entry.status)
        (escape_markdown_cell entry.official_semantics_source)
        (entry.smoke_test
         |> Option.value ~default:"not implemented yet"
         |> escape_markdown_cell))
  in
  String.concat "\n" (header @ rows) ^ "\n"
