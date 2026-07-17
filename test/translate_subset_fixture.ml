let write_file path contents =
  let channel = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)

let strip_maude_suffix path =
  if Filename.check_suffix path ".maude" then Filename.chop_suffix path ".maude"
  else path

let output_load output builtins =
  if Filename.dirname output = Filename.dirname builtins then
    output |> Filename.basename |> strip_maude_suffix
  else strip_maude_suffix output

let load files =
  files
  |> List.concat_map Frontend.Parse.parse_file
  |> Frontend.Elab.elab
  |> fst

let () =
  match Array.to_list Sys.argv with
  | _ :: output :: builtins :: files when files <> [] ->
    let result = Translator.Driver.translate (load files) in
    prerr_endline
      ("[spec2maude] " ^ Translator.Diagnostics.summary result.diagnostics);
    if Translator.Driver.has_fatal_diagnostics result then (
      prerr_endline (Translator.Diagnostics.render_all result.diagnostics);
      exit 1
    );
    write_file output (Translator.Driver.emit result);
    write_file builtins
      (Translator.Driver.emit_builtins
         ~output_load:(output_load output builtins) result)
  | _ ->
    prerr_endline
      "usage: translate_subset_fixture OUTPUT BUILTINS SPECTEC...";
    exit 2
