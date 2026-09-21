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
  let translation = Def.translate_script script in
  let sorts : Maude_il.top_level =
    Module
      { name = "SPEC2MAUDE-SORTS"
      ; kind = Functional
      ; imports = [Protecting (module_name "SPECTEC-TERM")]
      ; statements = translation.sort_statements
      }
  in
  let generated : Maude_il.top_level =
    Module
      { name = "SPEC2MAUDE-GENERATED"
      ; kind = System
      ; imports =
          [Maude_il.Protecting (module_name "SPECTEC-PRETYPE")]
      ; statements = translation.list_subsorts @ translation.generated_statements
      }
  in
  let typed_lists : Maude_il.top_level =
    Module
      { name = "SPEC2MAUDE-TYPES"
      ; kind = Maude_il.Functional
      ; imports =
          [Maude_il.Protecting (module_name "SPEC2MAUDE-SORTS")]
          @ translation.list_imports
      ; statements = translation.list_statements
      }
  in
  (* Native typed lists precede the backend's common list overloads; the
     source-derived subsort connections follow them in the generated module. *)
  let types =
    Maude_emit.emit_top_levels
      (sorts :: translation.list_views @ [typed_lists]) ^ "\n"
  in
  types, Maude_emit.emit_top_levels [generated] ^ "\n"

let write_file path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)

let () =
  let output = ref default_output in
  let files = ref [] in
  let options =
    [ "-o", Arg.Set_string output, "FILE write generated Maude and sibling types.maude"
    ; "--output", Arg.Set_string output, "FILE write generated Maude and sibling types.maude"
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
    let types_output = Filename.concat (Filename.dirname !output) "types.maude" in
    if Filename.basename !output = "types.maude" then
      die "types.maude is reserved for generated type declarations";
    let types, generated = files |> load_script |> emit_script in
    write_file types_output types;
    write_file !output generated;
    Printf.eprintf "[spec2maude] wrote %s and %s from %d SpecTec files\n"
      types_output !output (List.length files)
  with
  | Util.Error.Error (region, message) ->
      Util.Error.print_error region message;
      exit 1
  | Sys_error message -> die message
