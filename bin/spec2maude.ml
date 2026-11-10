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

(* The names declared by op and ops in a builtin Maude file: the words
   from op or ops to the next ":", possibly over several lines. Comments
   (--- or *** to the end of a line) are skipped; nothing else is parsed. *)
let operator_names file =
  let uncomment line =
    let cut marker line =
      match Str.search_forward (Str.regexp_string marker) line 0 with
      | position -> String.sub line 0 position
      | exception Not_found -> line
    in
    line |> cut "---" |> cut "***"
  in
  let words =
    In_channel.with_open_bin file In_channel.input_all
    |> String.split_on_char '\n'
    |> List.map uncomment
    |> String.concat " "
    |> Str.split (Str.regexp "[ \t\r]+")
  in
  let rec names = function
    | ("op" | "ops") :: rest ->
        let rec declared = function
          | ":" :: rest -> [], rest
          | name :: rest -> let more, rest = declared rest in name :: more, rest
          | [] -> [], []
        in
        let declared, rest = declared rest in
        declared @ names rest
    | _ :: rest -> names rest
    | [] -> []
  in
  names words

let module_name name = Maude_il.ModuleName name

let emit_script builtin_names script =
  let translation = Def.translate_script ~builtin_names script in
  let sorts : Maude_il.top_level =
    Module
      { name = "SPEC2MAUDE-SORTS"
      ; kind = Functional
      ; imports = [Protecting (module_name "SPECTEC-SORTS")]
      ; statements = translation.sort_statements
      }
  in
  let generated : Maude_il.top_level =
    Module
      { name = "SPEC2MAUDE-GENERATED"
      ; kind = System
      ; imports =
          [Maude_il.Protecting (module_name "SPECTEC-SEMANTICS")]
      ; statements = translation.generated_statements
      }
  in
  let typed_lists : Maude_il.top_level =
    Module
      { name = "SPEC2MAUDE-TYPES"
      ; kind = Maude_il.Functional
      ; imports =
          [Maude_il.Protecting (module_name "SPEC2MAUDE-SORTS")]
      ; statements = translation.list_statements
      }
  in
  (* Typed lists are declared on the prelude LIST of SpectecTerminal,
     which backend/spectec-sorts.maude imports before this file. *)
  let types =
    Maude_emit.emit_top_levels [sorts; typed_lists] ^ "\n"
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
  let builtins = ref [] in
  (* After --builtins, .maude arguments are builtin files. *)
  let reading_builtins = ref false in
  let options =
    [ "-o", Arg.Set_string output, "FILE write generated Maude and sibling types.maude"
    ; "--output", Arg.Set_string output, "FILE write generated Maude and sibling types.maude"
    ; "--builtins", Arg.Set reading_builtins,
      "FILE... builtin Maude files whose op names generated names avoid"
    ]
  in
  let usage = "usage: spec2maude [-o FILE] [--builtins MAUDE ...] [SPECTEC ...]" in
  let argument file =
    if !reading_builtins && Filename.check_suffix file ".maude" then
      builtins := file :: !builtins
    else begin
      reading_builtins := false;
      files := file :: !files
    end
  in
  try
    Arg.parse options argument usage;
    let files =
      match List.rev !files with
      | [] -> sorted_spectec_files default_source_dir
      | files -> files
    in
    let types_output = Filename.concat (Filename.dirname !output) "types.maude" in
    if Filename.basename !output = "types.maude" then
      die "types.maude is reserved for generated type declarations";
    let builtin_names = List.concat_map operator_names (List.rev !builtins) in
    let types, generated = files |> load_script |> emit_script builtin_names in
    write_file types_output types;
    write_file !output generated;
    Printf.eprintf "[spec2maude] wrote %s and %s from %d SpecTec files\n"
      types_output !output (List.length files)
  with
  | Util.Error.Error (region, message) ->
      Util.Error.print_error region message;
      exit 1
  | Sys_error message -> die message
