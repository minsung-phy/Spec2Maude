module Parse = Wasm.Parse
module Script = Wasm.Script
module Source = Wasm.Source

module Counts = Map.Make (String)

type audit = {
  files : int;
  modules : int;
  encoded : int;
  failures : int Counts.t;
  issues : string list;
}

let add key counts =
  Counts.update key (function None -> Some 1 | Some n -> Some (n + 1)) counts

(* Wasm 1.0 and 2.0 scripts may use forms the current parser no longer
   reads (Legacy_wast). *)
let parse path =
  try
    if !Wasm_version.current = Wasm_version.V3 then Parse.Script.parse_file path
    else
      let text = In_channel.with_open_bin path In_channel.input_all in
      let ids = !Wasm_version.current = Wasm_version.V1 in
      let lexbuf = Lexing.from_string (Legacy_wast.normalize ~ids text) in
      Parse.Script.parse path lexbuf
  with
  | Parse.Syntax (at, message) | Wasm.Custom.Syntax (at, message) ->
      Ingress_error.raise ~region:at Ingress_error.Syntax path message
  | Sys_error message -> Ingress_error.raise Ingress_error.Io path message

let rec wast_files path =
  if Sys.is_directory path then
    Sys.readdir path
    |> Array.to_list
    |> List.sort String.compare
    |> List.concat_map (fun name -> wast_files (Filename.concat path name))
  else if Filename.check_suffix (String.lowercase_ascii path) ".wast" then
    [ path ]
  else
    []

let sources path =
  let paths =
    try wast_files path with Sys_error message ->
      Ingress_error.raise Ingress_error.Io path message
  in
  match paths with
  | [] ->
      Ingress_error.raise Ingress_error.Unsupported path
        "directory contains no .wast scripts"
  | _ -> paths

let rec fold_modules f acc = function
  | [] -> acc
  | command :: rest ->
      let acc =
        match command.Source.it with
        | Script.Module (_, def) -> f acc def
        | Script.Meta {Source.it = Script.Script (_, script); _} ->
            fold_modules f acc script
        | Script.Meta _ | Script.Instance _ | Script.Register _ | Script.Action _
        | Script.Assertion _ -> acc
      in
      fold_modules f acc rest

let fold_suite f initial paths =
  List.fold_left
    (fun acc source -> fold_modules (f source) acc (parse source)) initial paths

let empty_audit paths =
  {files = List.length paths; modules = 0; encoded = 0;
   failures = Counts.empty; issues = []}

let failed audit error =
  {audit with
   failures = add error.Ingress_error.message audit.failures;
   issues = Ingress_error.to_string error :: audit.issues}

let audit_suite path =
  let paths = sources path in
  let encode source audit def =
    let audit = {audit with modules = audit.modules + 1} in
    try
      let m = Frontend.of_definition source def in
      ignore (Encode.module_ m);
      {audit with encoded = audit.encoded + 1}
    with Ingress_error.Error error -> failed audit error
  in
  fold_suite encode (empty_audit paths) paths

let audit_files (audit : audit) = audit.files
let audit_modules (audit : audit) = audit.modules
let audit_encoded (audit : audit) = audit.encoded
let audit_failures (audit : audit) = Counts.bindings audit.failures
let audit_issues (audit : audit) = List.rev audit.issues
