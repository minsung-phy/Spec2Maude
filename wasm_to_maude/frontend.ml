open Wasm

type module_ = {
  source : string;
  ast : Ast.module_;
  custom : Custom.section list;
}

type invocation_error =
  | Missing_export
  | Non_function_export
  | Unresolved_function_type
  | Wrong_arity
  | Wrong_argument_type of int

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

let export_type m name =
  let Types.ModuleT (_, exports) = Ast.moduletype_of m.ast in
  List.find_map
    (function
      | Types.ExportT (export_name, actual) when export_name = name ->
          Some actual
      | Types.ExportT _ -> None)
    exports

let function_parameters m name =
  match export_type m name with
  | Some (Types.ExternFuncT (Types.Def deftype)) ->
      Ok (Types.(functype_of_comptype (expand_deftype deftype)) |> fst)
  | Some (Types.ExternFuncT (Types.Idx _)) -> Error Unresolved_function_type
  | Some _ -> Error Non_function_export
  | None -> Error Missing_export

let validate_invocation m name arguments =
  match function_parameters m name with
  | Error _ as error -> error
  | Ok parameters when List.length arguments <> List.length parameters ->
      Error Wrong_arity
  | Ok parameters ->
      let rec check index arguments parameters =
        match arguments, parameters with
        | [], [] -> Ok ()
        | argument :: arguments, parameter :: parameters ->
            if Match.match_valtype [] argument parameter then
              check (index + 1) arguments parameters
            else Error (Wrong_argument_type index)
        | [], _ :: _ | _ :: _, [] -> Error Wrong_arity
      in
      check 0 arguments parameters
