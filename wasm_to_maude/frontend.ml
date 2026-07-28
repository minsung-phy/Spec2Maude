open Wasm

type module_ = {
  source : string;
  ast : Ast.module_;
  custom : Custom.section list;
}

let validate source (ast, custom) =
  try
    ignore (Valid.check_module_with_custom (ast, custom));
    {source; ast; custom}
  with
  | Valid.Invalid (at, message) ->
      Ingress_error.raise ~region:at Ingress_error.Invalid source message
  | Custom.Invalid (at, message) ->
      Ingress_error.raise ~region:at Ingress_error.Invalid source message

let rec of_definition source def =
  match def.Source.it with
  | Script.Textual (ast, custom) -> validate source (ast, custom)
  | Script.Encoded (name, bytes) ->
      (try validate source (Decode.decode_with_custom name bytes.it) with
       | Decode.Code (at, message) ->
           Ingress_error.raise ~region:at Ingress_error.Syntax source message
       | Custom.Code (at, message) ->
           Ingress_error.raise ~region:at Ingress_error.Syntax source message)
  | Script.Quoted (_, text) ->
      (try
         let _, def' = Parse.Module.parse_string ~offset:text.at text.it in
         of_definition source def'
       with
       | Parse.Syntax (at, message) | Custom.Syntax (at, message) ->
           Ingress_error.raise ~region:at Ingress_error.Syntax source message)

let text ~name contents =
  try
    let _, def = Parse.Module.parse_string contents in
    of_definition name def
  with Parse.Syntax (at, message) | Custom.Syntax (at, message) ->
    Ingress_error.raise ~region:at Ingress_error.Syntax name message

let binary ~name bytes =
  try validate name (Decode.decode_with_custom name bytes)
  with Decode.Code (at, message) | Custom.Code (at, message) ->
    Ingress_error.raise ~region:at Ingress_error.Syntax name message

let read_file path =
  try
    let ic = open_in_gen [Open_rdonly; Open_binary] 0 path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let size = in_channel_length ic in
        really_input_string ic size)
  with Sys_error message -> Ingress_error.raise Ingress_error.Io path message

let load path =
  match String.lowercase_ascii (Filename.extension path) with
  | ".wat" ->
      (try
         let _, def = Parse.Module.parse_file path in
         of_definition path def
       with
       | Parse.Syntax (at, message) | Custom.Syntax (at, message) ->
           Ingress_error.raise ~region:at Ingress_error.Syntax path message
       | Sys_error message -> Ingress_error.raise Ingress_error.Io path message)
  | ".wasm" -> binary ~name:path (read_file path)
  | ext ->
      Ingress_error.raise Ingress_error.Unsupported path
        (Printf.sprintf "expected a .wat or .wasm module, found %S" ext)

let import_count m = List.length m.ast.Source.it.Ast.imports
