open Spec2maude_translate

let default_source_dir = "spectec/wasm-3.0"
let default_output = "translator/generated/output.maude"

let die message =
  prerr_endline ("spec2maude: " ^ message);
  exit 2

let sorted_spectec_files dir =
  if not (Sys.file_exists dir) then die ("cannot find " ^ dir);
  Sys.readdir dir
  |> Array.to_list
  |> List.filter (fun name -> Filename.check_suffix name ".spectec")
  |> List.sort String.compare
  |> List.map (Filename.concat dir)

let load_script files =
  files
  |> List.concat_map Frontend.Parse.parse_file
  |> Frontend.Elab.elab
  |> fst

let module_name name = Maude_il.ModuleName name

let emit_script script =
  let translation = Definition.translate_script script in
  let sorts : Maude_il.top_level =
    Module
      { name = "SPEC2MAUDE-SORTS"
      ; kind = Functional
      ; imports = [Protecting (module_name "DSL-TERM")]
      ; statements = translation.sort_statements
      }
  in
  let generated : Maude_il.top_level =
    Module
      { name = "SPEC2MAUDE-GENERATED"
      ; kind = System
      ; imports =
          [ Maude_il.Protecting (module_name "SPECTEC-SUPPORT")
          ; Maude_il.Protecting (module_name "SPEC2MAUDE-SORTS")
          ]
      ; statements = translation.generated_statements
      }
  in
  let pretype : Maude_il.top_level =
    Module
      { name = "DSL-PRETYPE"
      ; kind = Maude_il.Functional
      ; imports =
          [ Maude_il.Protecting (module_name "DSL-PRETYPE-BASE")
          ; Maude_il.Protecting (module_name "SPEC2MAUDE-SORTS")
          ]
          @ translation.list_imports
      ; statements = translation.list_statements
      }
  in
  Maude_emit.emit_top_levels
    (sorts :: translation.list_views
     @ [ pretype
       ; Maude_il.Load "../backend/spectec-support/support.maude"
       ; generated
       ]) ^ "\n"

let write_file path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)

let () =
  let output = ref default_output in
  let files = ref [] in
  let options =
    [ "-o", Arg.Set_string output, "FILE write generated Maude to FILE"
    ; "--output", Arg.Set_string output, "FILE write generated Maude to FILE"
    ]
  in
  let usage = "usage: spec2maude [-o FILE] [SPECTEC ...]" in
  try
    Arg.parse options (fun file -> files := file :: !files) usage;
    let files =
      match List.rev !files with
      | [] -> sorted_spectec_files default_source_dir
      | files -> files
    in
    files |> load_script |> emit_script |> write_file !output;
    Printf.eprintf "[spec2maude] wrote %s from %d SpecTec files\n"
      !output (List.length files)
  with
  | Util.Error.Error (region, message) ->
      Util.Error.print_error region message;
      exit 1
  | Sys_error message -> die message
