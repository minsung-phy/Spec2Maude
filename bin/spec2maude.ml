let die message =
  prerr_endline ("spec2maude: " ^ message);
  exit 2

let usage ?(code = 2) () =
  prerr_endline
    "Usage:\n  spec2maude translate [-o FILE] [--builtins FILE] [--builtin-report FILE] [SPECTEC...]\n\nIf no input files are provided, translate reads wasm-3.0/*.spectec in lexical order.";
  exit code

let sorted_default_spectec_files () =
  let dir = "wasm-3.0" in
  if not (Sys.file_exists dir) then die "cannot find wasm-3.0/";
  Sys.readdir dir
  |> Array.to_list
  |> List.filter (fun name -> Filename.check_suffix name ".spectec")
  |> List.sort String.compare
  |> List.map (Filename.concat dir)

let write_file path contents =
  let channel = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)

let strip_maude_suffix path =
  let suffix = ".maude" in
  let path_len = String.length path in
  let suffix_len = String.length suffix in
  if path_len >= suffix_len
     && String.sub path (path_len - suffix_len) suffix_len = suffix
  then
    String.sub path 0 (path_len - suffix_len)
  else
    path

let parse_translate_args args =
  let output = ref "output.maude" in
  let builtins_output = ref None in
  let builtin_report = ref None in
  let files = ref [] in
  let rec loop = function
    | [] -> ()
    | ("-o" | "--output") :: path :: rest ->
      output := path;
      loop rest
    | ("-o" | "--output") :: [] ->
      die "translate expects a path after -o/--output"
    | "--builtins" :: path :: rest ->
      builtins_output := Some path;
      loop rest
    | "--builtins" :: [] ->
      die "translate expects a path after --builtins"
    | "--builtin-report" :: path :: rest ->
      builtin_report := Some path;
      loop rest
    | "--builtin-report" :: [] ->
      die "translate expects a path after --builtin-report"
    | "--help" :: _ -> usage ~code:0 ()
    | file :: rest ->
      files := !files @ [ file ];
      loop rest
  in
  loop args;
  let files =
    match !files with
    | [] -> sorted_default_spectec_files ()
    | files -> files
  in
  !output, !builtins_output, !builtin_report, files

let load_il_script files =
  let el_script =
    files
    |> List.map Frontend.Parse.parse_file
    |> List.concat
  in
  fst (Frontend.Elab.elab el_script)

let cmd_translate args =
  let output, builtins_output, builtin_report, files = parse_translate_args args in
  let il_script = load_il_script files in
  let result = Translator.Driver.translate il_script in
  write_file output (Translator.Driver.emit result);
  prerr_endline ("[spec2maude] wrote " ^ output);
  (match builtins_output with
  | None -> ()
  | Some path ->
    write_file path
      (Translator.Driver.emit_builtins
         ~output_load:(strip_maude_suffix output)
         result);
    prerr_endline ("[spec2maude] wrote " ^ path));
  (match builtin_report with
  | None -> ()
  | Some path ->
    write_file path (Translator.Driver.emit_builtin_report result);
    prerr_endline ("[spec2maude] wrote " ^ path));
  prerr_endline ("[spec2maude] " ^ Translator.Diagnostics.summary result.diagnostics);
  if result.diagnostics <> [] then
    prerr_endline (Translator.Diagnostics.render_all result.diagnostics);
  if Translator.Driver.has_fatal_diagnostics result then exit 1

let () =
  try
    match Array.to_list Sys.argv with
    | [ _ ] -> usage ()
    | _ :: "translate" :: args -> cmd_translate args
    | _ :: "--help" :: _ | _ :: "-h" :: _ -> usage ~code:0 ()
    | _ :: command :: _ -> die ("unknown command " ^ command)
    | [] -> usage ()
  with
  | Util.Error.Error (region, message) ->
    Util.Error.print_error region message;
    exit 1
