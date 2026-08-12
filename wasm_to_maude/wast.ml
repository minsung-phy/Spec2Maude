module Parse = Wasm.Parse
module Script = Wasm.Script
module Source = Wasm.Source

module Counts = Map.Make (String)

type summary = int Counts.t
type suite = { files : int; summary : summary }
type audit = {
  files : int;
  modules : int;
  encoded : int;
  failures : int Counts.t;
  issues : string list;
}

type typecheck_case = {
  index : int;
  source : string;
  term : string;
  checks : Encode.check list;
}

let add key counts =
  Counts.update key (function None -> Some 1 | Some n -> Some (n + 1)) counts

let assertion = function
  | Script.AssertMalformed _ -> "assert_malformed"
  | Script.AssertMalformedCustom _ -> "assert_malformed_custom"
  | Script.AssertInvalid _ -> "assert_invalid"
  | Script.AssertInvalidCustom _ -> "assert_invalid_custom"
  | Script.AssertUnlinkable _ -> "assert_unlinkable"
  | Script.AssertUninstantiable _ -> "assert_uninstantiable"
  | Script.AssertReturn _ -> "assert_return"
  | Script.AssertException _ -> "assert_exception"
  | Script.AssertTrap _ -> "assert_trap"
  | Script.AssertExhaustion _ -> "assert_exhaustion"

let rec commands counts = function
  | [] -> counts
  | command :: rest ->
      let counts =
        match command.Source.it with
        | Script.Module _ -> add "module" counts
        | Script.Instance _ -> add "instance" counts
        | Script.Register _ -> add "register" counts
        | Script.Action _ -> add "action" counts
        | Script.Assertion a -> add (assertion a.Source.it) counts
        | Script.Meta meta ->
            (match meta.Source.it with
             | Script.Script (_, script) ->
                 commands (add "meta_script" counts) script
             | Script.Input _ -> add "meta_input" counts
             | Script.Output _ -> add "meta_output" counts)
      in
      commands counts rest

let load path =
  try commands Counts.empty (Parse.Script.parse_file path) with
  | Parse.Syntax (at, message) ->
      Ingress_error.raise ~region:at Ingress_error.Syntax path message
  | Sys_error message -> Ingress_error.raise Ingress_error.Io path message

let merge left right =
  Counts.union (fun _ x y -> Some (x + y)) left right

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

let load_suite path =
  let paths = sources path in
  let summary =
    List.fold_left (fun counts file -> merge counts (load file))
      Counts.empty paths
  in
  {files = List.length paths; summary}

let rec audit_commands source audit = function
  | [] -> audit
  | command :: rest ->
      let audit =
        match command.Source.it with
        | Script.Module (_, def) ->
            let audit = {audit with modules = audit.modules + 1} in
            (try
               let m = Frontend.of_definition source def in
               ignore (Encode.module_ m);
               {audit with encoded = audit.encoded + 1}
             with Ingress_error.Error error ->
               {audit with
                failures = add error.message audit.failures;
                issues = Ingress_error.to_string error :: audit.issues})
        | Script.Meta meta ->
            (match meta.Source.it with
             | Script.Script (_, script) -> audit_commands source audit script
             | Script.Input _ | Script.Output _ -> audit)
        | Script.Instance _ | Script.Register _ | Script.Action _
        | Script.Assertion _ -> audit
      in
      audit_commands source audit rest

let audit_suite path =
  let paths = sources path in
  List.fold_left
    (fun audit file ->
      let script =
        try Parse.Script.parse_file file with
        | Parse.Syntax (at, message) ->
            Ingress_error.raise ~region:at Ingress_error.Syntax file message
        | Sys_error message ->
            Ingress_error.raise Ingress_error.Io file message
      in
      audit_commands file audit script)
    {files = List.length paths; modules = 0; encoded = 0;
     failures = Counts.empty; issues = []}
    paths

let typecheck_suite ?(details = false) ~semantics path =
  let paths = sources path in
  let rec collect source cases audit = function
        | [] -> cases, audit
        | command :: rest ->
            let cases, audit =
              match command.Source.it with
              | Script.Module (_, def) ->
                  let audit = {audit with modules = audit.modules + 1} in
                  (try
                     let m = Frontend.of_definition source def in
                     let case =
                       { index = audit.encoded + 1;
                         source;
                         term = Maude_term.to_string (Encode.module_ m);
                         checks = if details then Encode.module_checks m else [] }
                     in
                     case :: cases, {audit with encoded = audit.encoded + 1}
                   with Ingress_error.Error error ->
                     cases,
                     {audit with
                      failures = add error.message audit.failures;
                      issues = Ingress_error.to_string error :: audit.issues})
              | Script.Meta meta ->
                  (match meta.Source.it with
                   | Script.Script (_, script) -> collect source cases audit script
                   | Script.Input _ | Script.Output _ -> cases, audit)
              | Script.Instance _ | Script.Register _ | Script.Action _
              | Script.Assertion _ -> cases, audit
            in
            collect source cases audit rest
  in
  let cases, audit =
    List.fold_left
      (fun (cases, audit) file ->
        let script =
          try Parse.Script.parse_file file with
          | Parse.Syntax (at, message) ->
              Ingress_error.raise ~region:at Ingress_error.Syntax file message
          | Sys_error message ->
              Ingress_error.raise Ingress_error.Io file message
        in
        collect file cases audit script)
      ([],
       {files = List.length paths; modules = 0; encoded = 0;
        failures = Counts.empty; issues = []})
      paths
  in
  let cases = List.rev cases in
  let buffer = Buffer.create 65536 in
  Buffer.add_string buffer ("load " ^ semantics ^ "\n\n");
  List.iter
    (fun case ->
      Buffer.add_string buffer
        (Printf.sprintf "--- module %d: %s\n" case.index case.source);
      List.iteri
        (fun detail check ->
          Buffer.add_string buffer
            (Printf.sprintf "--- module %d, check %d: %s\n"
               case.index (detail + 1) (Encode.check_label check));
          Buffer.add_string buffer
            (Printf.sprintf "red in WASM-BUILTINS : %s .\n\n"
               (Maude_term.to_string (Encode.check_term check))))
        case.checks;
      Buffer.add_string buffer
        (Printf.sprintf
           "red in WASM-BUILTINS : typecheck(\n%s,\nsyn.module) .\n\n"
           case.term))
    cases;
  Buffer.contents buffer, audit

let to_lines counts = Counts.bindings counts
let total counts = Counts.fold (fun _ n sum -> sum + n) counts 0
let files (suite : suite) = suite.files
let summary (suite : suite) = suite.summary
let audit_files (audit : audit) = audit.files
let audit_modules (audit : audit) = audit.modules
let audit_encoded (audit : audit) = audit.encoded
let audit_failures (audit : audit) = Counts.bindings audit.failures
let audit_issues (audit : audit) = List.rev audit.issues
