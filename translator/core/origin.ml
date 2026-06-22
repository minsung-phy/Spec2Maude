open Util.Source

type t =
  { region : region
  ; path : string list
  ; ast_constructor : string
  ; source_echo : string option
  }

let make ?source_echo ?(path = []) ~ast_constructor region =
  { region; path; ast_constructor; source_echo }

let synthetic ?source_echo ?(path = []) ~ast_constructor label =
  let region = region_of_file ("<" ^ label ^ ">") in
  make ?source_echo ~path ~ast_constructor region

let with_child ?source_echo t segment ~ast_constructor region =
  make ?source_echo ~path:(t.path @ [ segment ]) ~ast_constructor region

let path t =
  match t.path with
  | [] -> "<root>"
  | segments -> String.concat "/" segments

let source_location t =
  string_of_region t.region

let summary t =
  Printf.sprintf "%s / %s / %s" (source_location t) (path t) t.ast_constructor

let to_comment t =
  "--- origin: " ^ summary t
